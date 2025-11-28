from dagster import Definitions

# Import assets
from .assets.init_inputs import init_inputs
from .assets.raw_satellite import raw_satellite_raster
from .assets.field_processing import field_daily_metrics

# Import resources
from .resources.minio_resource import MinIOResource


# Definitions entrypoint
defs = Definitions(
    assets=[
        init_inputs,
        raw_satellite_raster,
        field_daily_metrics,
    ],
    resources={
        "minio_client": MinIOResource(),
    },
)
