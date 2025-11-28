"""
Raw satellite raster generation with correct temporal dependency logic:

The asset fails ONLY when the previous partition is missing AND lies
inside the valid partition range (>= start date). Backfills outside
the range or isolated computations do NOT fail.
"""

import io
import json
import os
import requests
from datetime import datetime, timedelta
import numpy as np

from dagster import (
    AssetExecutionContext,
    AssetIn,
    DailyPartitionsDefinition,
    TimeWindowPartitionMapping,
    Nothing,
    asset,
)

from dagster_project.resources.minio_resource import MinIOResource


# Daily partitions
daily_partitions = DailyPartitionsDefinition(start_date="2024-01-01")


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _bucket() -> str:
    return os.getenv("MINIO_BUCKET", "dagster-bucket")


def _minio_get_json(client, bucket: str, key: str) -> dict:
    resp = client.get_object(bucket_name=bucket, object_name=key)
    return json.loads(resp.read().decode("utf-8"))


def _fetch_nasa_weather(date, lat, lon, context):
    url = "https://power.larc.nasa.gov/api/temporal/daily/point"
    ds = date.strftime("%Y%m%d")
    params = {
        "parameters": "T2M,PRECTOTCORR,ALLSKY_SFC_SW_DWN",
        "community": "AG",
        "longitude": lon,
        "latitude": lat,
        "start": ds,
        "end": ds,
        "format": "JSON",
    }
    try:
        context.log.info(f"Fetching NASA weather for {ds}")
        r = requests.get(url, params=params, timeout=15)
        r.raise_for_status()
        p = r.json()["properties"]["parameter"]
        return {
            "temperature": p["T2M"][ds],
            "precipitation": p["PRECTOTCORR"][ds],
            "solar_radiation": p["ALLSKY_SFC_SW_DWN"][ds],
        }
    except:
        context.log.warning("NASA fetch failed, using defaults.")
        return {"temperature": 20.0, "precipitation": 2.0, "solar_radiation": 15.0}


def _simulate_ndvi_with_weather(date, T, R, S, prev_ndvi):
    rows, cols = 100, 100
    day = date.timetuple().tm_yday

    x = np.linspace(0, 1, cols)
    y = np.linspace(0, 1, rows)
    xx, yy = np.meshgrid(x, y)

    spatial = 0.5 + 0.5 * (xx - .5)*(yy - .5)*4
    season = np.sin(2*np.pi*day/365)*0.3 + 0.5

    temp_factor = np.clip(1 - abs(T-20)/40, 0.3, 1.0)
    rain_factor = np.clip(np.log1p(R)/np.log1p(20), 0.5, 1.3)
    solar_factor = np.clip(S/18, 0.4, 1.2)
    noise = np.random.normal(0, 0.05, (rows, cols))

    weather_ndvi = season * spatial * temp_factor * rain_factor * solar_factor + noise

    if prev_ndvi is not None:
        ndvi = 0.7 * prev_ndvi + 0.3 * weather_ndvi
    else:
        ndvi = weather_ndvi

    return np.clip(ndvi, 0, 1)


# ------------------------------------------------------------------
# Proper temporal dependency logic (backfill friendly)
# ------------------------------------------------------------------

def _load_prev_raster(client, bucket, prev_date, first_date, context):
    """
    Load previous day's raster with correct dependency rules.

    FAIL:
        - if prev_date >= start_date  (inside range)
        - AND raster does NOT exist

    OK:
        - if prev_date < start_date  (out-of-range backfill)
        - if first partition
        - if raster exists
    """
    key = f"raw_raster/{prev_date}/raster.csv"

    # prev_date BEFORE partition range → backfill OK
    if prev_date < first_date:
        context.log.info(
            f"Previous date {prev_date} is before partition start → OK, no dependency."
        )
        return None

    # prev_date >= start_date → must exist
    try:
        resp = client.get_object(bucket_name=bucket, object_name=key)
        rows = resp.read().decode("utf-8").splitlines()
        return np.array([[float(v) for v in line.split(",")] for line in rows])
    except:
        raise RuntimeError(
            f"❌ Missing previous-day raster for {prev_date}. "
            "This date is inside the valid range → temporal continuity violated."
        )


# ------------------------------------------------------------------
# Asset definition
# ------------------------------------------------------------------

@asset(
    name="raw_satellite_raster",
    partitions_def=daily_partitions,
    required_resource_keys={"minio_client"},
    ins={
        "previous_day_raster": AssetIn(
            "raw_satellite_raster",
            partition_mapping=TimeWindowPartitionMapping(start_offset=-1, end_offset=-1),
            dagster_type=Nothing,
        )
    },
)
def raw_satellite_raster(context: AssetExecutionContext):
    minio: MinIOResource = context.resources.minio_client
    client = minio.get_client()
    bucket = _bucket()

    date = datetime.strptime(context.partition_key, "%Y-%m-%d")
    prev_date = (date - timedelta(days=1)).strftime("%Y-%m-%d")
    first_date = daily_partitions.start.strftime("%Y-%m-%d")

    # bounding box
    try:
        bbox = _minio_get_json(client, bucket, "inputs/bbox.json")
        lon = (bbox["xmin"] + bbox["xmax"]) / 2
        lat = (bbox["ymin"] + bbox["ymax"]) / 2
    except:
        lon, lat = 6.0, 49.8

    prev_ndvi = _load_prev_raster(client, bucket, prev_date, first_date, context)
    weather = _fetch_nasa_weather(date, lat, lon, context)

    raster = _simulate_ndvi_with_weather(
        date,
        weather["temperature"],
        weather["precipitation"],
        weather["solar_radiation"],
        prev_ndvi
    )

    # Save
    data = "\n".join(",".join(f"{v:.4f}" for v in row) for row in raster).encode()
    key = f"raw_raster/{context.partition_key}/raster.csv"
    client.put_object(bucket, key, io.BytesIO(data), len(data), "text/csv")

    context.log.info(f"Saved raster: minio://{bucket}/{key}")
    return {"key": key}
