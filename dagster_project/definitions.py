from dagster import Definitions

from dagster_project.resources.minio_resource import MinIOResource
from dagster_project.assets.init_inputs import init_inputs
from dagster_project.assets.raw_satellite import raw_satellite_raster
from dagster_project.assets.field_processing import field_daily_metrics

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
