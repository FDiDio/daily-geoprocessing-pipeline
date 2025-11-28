"""
Field metrics with correct temporal dependency logic:

Fail ONLY when:
- prev_date >= start_date  (inside valid range)
- AND previous raster/metrics are missing

Allow:
- first partition
- isolated backfills
- dates before the start date
"""

import io
import json
from datetime import datetime, timedelta

import geojson
import numpy as np
import pandas as pd

from dagster import (
    AssetExecutionContext,
    AssetIn,
    LastPartitionMapping,
    Nothing,
    asset,
)

from dagster_project.resources.minio_resource import MinIOResource
from dagster_project.assets.raw_satellite import daily_partitions, _bucket


# ------------------------------------------------------------------
# MinIO helpers
# ------------------------------------------------------------------

def _read_geojson(client, bucket, key):
    text = client.get_object(bucket, key).read().decode("utf-8")
    gj = geojson.loads(text)
    return gj.features if isinstance(gj, geojson.FeatureCollection) else [gj]


def _read_raster(client, bucket, key):
    body = client.get_object(bucket, key).read().decode("utf-8")
    return np.array([[float(v) for v in line.split(",")] for line in body.splitlines()])


# ------------------------------------------------------------------
# Temporal logic
# ------------------------------------------------------------------

def _load_prev_raster(client, bucket, prev_date, first_date, context):
    """Same logic as raster asset."""
    key = f"raw_raster/{prev_date}/raster.csv"

    if prev_date < first_date:
        context.log.info(f"{prev_date} < {first_date}: no dependency → OK.")
        return None

    try:
        return _read_raster(client, bucket, key)
    except:
        raise RuntimeError(
            f"❌ Missing previous-day raster for {prev_date}. Inside range → continuity violated."
        )


def _load_prev_metrics(client, bucket, prev_date, first_date, context):
    key = f"field_metrics/{prev_date}/field_metrics.parquet"

    if prev_date < first_date:
        context.log.info(f"{prev_date} < {first_date}: no prev metrics required.")
        return None

    try:
        raw = client.get_object(bucket, key).read()
        return pd.read_parquet(io.BytesIO(raw))
    except:
        raise RuntimeError(
            f"❌ Missing previous-day metrics for {prev_date}. Inside range → continuity violated."
        )


# ------------------------------------------------------------------
# Asset
# ------------------------------------------------------------------

@asset(
    name="field_daily_metrics",
    partitions_def=daily_partitions,
    required_resource_keys={"minio_client"},
    ins={
        "previous_day_raster": AssetIn(
            "raw_satellite_raster",
            partition_mapping=LastPartitionMapping(),
            dagster_type=Nothing,
        )
    },
)
def field_daily_metrics(context: AssetExecutionContext):
    minio: MinIOResource = context.resources.minio_client
    client = minio.get_client()
    bucket = _bucket()

    date = datetime.strptime(context.partition_key, "%Y-%m-%d")
    prev_date = (date - timedelta(days=1)).strftime("%Y-%m-%d")
    first_date = daily_partitions.start.strftime("%Y-%m-%d")

    # Strict or flexible loading
    prev_raster = _load_prev_raster(client, bucket, prev_date, first_date, context)
    prev_metrics = _load_prev_metrics(client, bucket, prev_date, first_date, context)

    # If prev_raster == None and prev_date < first_date -> first partition or backfill
    if prev_raster is None:
        key = f"raw_raster/{context.partition_key}/raster.csv"
        prev_raster = _read_raster(client, bucket, key)

    fields = _read_geojson(client, bucket, "inputs/fields.geojson")

    records = []
    raster = prev_raster
    ndvi_mean = float(raster.mean())
    day = date.timetuple().tm_yday

    for feat in fields:
        props = feat.properties or {}
        field_id = props.get("field_id")
        crop_type = props.get("crop_type", "unknown")

        # Planting date skip
        planting = props.get("planting_date")
        if planting:
            if date.date() < datetime.strptime(planting, "%Y-%m-%d").date():
                continue

        rainfall = max(0.0, 5.0 * np.sin(2*np.pi*(day/365)) + 5)
        soil = float(np.clip(ndvi_mean * 0.6 + rainfall / 50, 0, 1))

        stress = float(np.clip(1 - ndvi_mean + np.random.normal(0, .02), 0, 1))

        # cumulative
        if prev_metrics is not None:
            row = prev_metrics[prev_metrics["field_id"] == field_id]
            prev_c = row["cumulative_stress_index"].iloc[0] if not row.empty else stress
            cumulative = min(1.0, prev_c + stress * 0.1)
        else:
            cumulative = stress

        records.append({
            "field_id": field_id,
            "date": date.date().isoformat(),
            "crop_type": crop_type,
            "ndvi_mean": ndvi_mean,
            "rainfall_mm": rainfall,
            "soil_moisture": soil,
            "crop_stress_index": stress,
            "cumulative_stress_index": cumulative,
        })

    df = pd.DataFrame(records)

    # Save
    key = f"field_metrics/{context.partition_key}/field_metrics.parquet"
    buf = io.BytesIO()
    df.to_parquet(buf, index=False)
    buf.seek(0)

    client.put_object(bucket, key, buf, len(buf.getbuffer()))

    context.log.info(f"Saved field metrics: minio://{bucket}/{key}")
    return {"key": key}
