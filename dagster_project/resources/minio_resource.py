# dagster_project/resources/minio_resource.py

import os
from minio import Minio
from dagster import ConfigurableResource

class MinIOResource(ConfigurableResource):
    endpoint: str = os.getenv("MINIO_ENDPOINT", "minio:9000")
    access_key: str = os.getenv("MINIO_ACCESS_KEY", "admin")
    secret_key: str = os.getenv("MINIO_SECRET_KEY", "admin123")
    secure: bool = False

    def get_client(self) -> Minio:
        return Minio(
            endpoint=self.endpoint,
            access_key=self.access_key,
            secret_key=self.secret_key,
            secure=self.secure,
        )
