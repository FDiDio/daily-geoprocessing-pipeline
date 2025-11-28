"""
Asset for initializing monitoring inputs from configuration file.

This module loads bounding box and field definitions from an external YAML
configuration file and uploads them to MinIO storage. All data is fixed and
defined in the configuration - no randomization.

Configuration file: config/fields.yaml (or CONFIG_PATH environment variable)
"""

import io
import json
import os
import yaml
from pathlib import Path

from dagster import asset
from dagster_project.resources.minio_resource import MinIOResource


def _load_config() -> dict:
    """
    Load configuration from YAML file.
    
    Looks for configuration at:
    1. Path specified in CONFIG_PATH environment variable
    2. Default: config/fields.yaml
    
    Returns:
        Configuration dictionary with bbox and fields
    
    Raises:
        FileNotFoundError: If configuration file doesn't exist
    """
    config_path = os.getenv("CONFIG_PATH", "config/fields.yaml")
    config_file = Path(config_path)
    
    if not config_file.exists():
        raise FileNotFoundError(
            f"Configuration file not found: {config_path}\n"
            f"Please create config/fields.yaml or set CONFIG_PATH environment variable"
        )
    
    with open(config_file, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    
    # Validate required keys
    if "bbox" not in config:
        raise ValueError("Configuration must contain 'bbox' key")
    if "fields" not in config:
        raise ValueError("Configuration must contain 'fields' key")
    
    return config


def _validate_bbox(bbox: dict) -> None:
    """
    Validate bounding box has required coordinates.
    
    Args:
        bbox: Bounding box dictionary
    
    Raises:
        ValueError: If bbox is invalid
    """
    required_keys = ["xmin", "ymin", "xmax", "ymax"]
    for key in required_keys:
        if key not in bbox:
            raise ValueError(f"Bounding box missing required key: {key}")
    
    # Check logical consistency
    if bbox["xmin"] >= bbox["xmax"]:
        raise ValueError("xmin must be less than xmax")
    if bbox["ymin"] >= bbox["ymax"]:
        raise ValueError("ymin must be less than ymax")


def _validate_field(field: dict, index: int) -> None:
    """
    Validate a field definition.
    
    Args:
        field: Field dictionary
        index: Field index (for error messages)
    
    Raises:
        ValueError: If field is invalid
    """
    required_keys = ["id", "crop_type", "planting_date", "polygon"]
    for key in required_keys:
        if key not in field:
            raise ValueError(f"Field {index} missing required key: {key}")
    
    # Validate polygon is closed
    polygon = field["polygon"]
    if len(polygon) < 4:
        raise ValueError(f"Field {field['id']}: polygon must have at least 4 points")
    if polygon[0] != polygon[-1]:
        raise ValueError(
            f"Field {field['id']}: polygon must be closed (first point = last point)"
        )


def _convert_to_geojson(fields_data: list) -> dict:
    """
    Convert field definitions to GeoJSON FeatureCollection.
    
    Args:
        fields_data: List of field dictionaries from config
    
    Returns:
        GeoJSON FeatureCollection with all fields
    """
    features = []
    
    for field in fields_data:
        feature = {
            "type": "Feature",
            "properties": {
                "field_id": field["id"],
                "crop_type": field["crop_type"],
                "planting_date": field["planting_date"],
            },
            "geometry": {
                "type": "Polygon",
                "coordinates": [field["polygon"]]
            }
        }
        features.append(feature)
    
    return {
        "type": "FeatureCollection",
        "features": features
    }


@asset(
    name="init_inputs",
    required_resource_keys={"minio_client"},
)
def init_inputs(context):
    """
    Load bounding box and field definitions from configuration file and upload to MinIO.
    
    This asset initializes the monitoring inputs by:
    1. Loading configuration from config/fields.yaml
    2. Validating bbox and field definitions
    3. Converting fields to GeoJSON format
    4. Uploading bbox.json and fields.geojson to MinIO
    
    The configuration file defines:
    - bbox: Geographic area to monitor (xmin, ymin, xmax, ymax)
    - fields: List of agricultural parcels with crop type, planting date, and polygon
    
    All data is fixed and reproducible - no randomization.
    The number of fields is flexible - the pipeline adapts automatically.
    
    Environment variables:
    - CONFIG_PATH: Path to configuration file (default: config/fields.yaml)
    
    Returns:
        Dictionary with bbox, field count, and field summary
    """
    minio: MinIOResource = context.resources.minio_client
    client = minio.get_client()
    bucket = "dagster-bucket"
    
    # Load configuration
    config_path = os.getenv('CONFIG_PATH', 'config/fields.yaml')
    try:
        config = _load_config()
        context.log.info(f"Loaded configuration from: {config_path}")
    except FileNotFoundError as e:
        context.log.error(f"Configuration file not found: {e}")
        raise
    except Exception as e:
        context.log.error(f"Failed to load configuration: {e}")
        raise
    
    # Extract and validate bbox
    bbox = config["bbox"]
    try:
        _validate_bbox(bbox)
        context.log.info(f"Bounding box validated")
        context.log.info(f"   West:  {bbox['xmin']:.3f}°E")
        context.log.info(f"   South: {bbox['ymin']:.3f}°N")
        context.log.info(f"   East:  {bbox['xmax']:.3f}°E")
        context.log.info(f"   North: {bbox['ymax']:.3f}°N")
    except ValueError as e:
        context.log.error(f"Invalid bounding box: {e}")
        raise
    
    # Extract and validate fields
    fields_data = config.get("fields", [])
    
    if not fields_data:
        context.log.warning("No fields defined in configuration")
    
    context.log.info(f"Number of fields: {len(fields_data)}")
    
    # Validate each field
    for i, field in enumerate(fields_data):
        try:
            _validate_field(field, i)
        except ValueError as e:
            context.log.error(f"Invalid field definition: {e}")
            raise
    
    # Log field details
    context.log.info("Field summary:")
    crop_counts = {}
    for field in fields_data:
        context.log.info(
            f"   {field['id']}: {field['crop_type']} "
            f"(planted {field['planting_date']})"
        )
        # Count crop types
        crop_type = field['crop_type']
        crop_counts[crop_type] = crop_counts.get(crop_type, 0) + 1
    
    # Log crop distribution
    context.log.info("Crop distribution:")
    for crop, count in sorted(crop_counts.items()):
        context.log.info(f"   {crop}: {count} fields")
    
    # Convert to GeoJSON
    try:
        fields_geojson = _convert_to_geojson(fields_data)
        context.log.info("Converted fields to GeoJSON format")
    except Exception as e:
        context.log.error(f"Failed to convert to GeoJSON: {e}")
        raise
    
    # Create bucket if needed
    try:
        if not client.bucket_exists(bucket_name=bucket):
            client.make_bucket(bucket_name=bucket)
            context.log.info(f"Created bucket: {bucket}")
        else:
            context.log.info(f"Bucket exists: {bucket}")
    except Exception as e:
        context.log.warning(f"Bucket check/creation: {e}")
    
    # Upload bbox.json
    try:
        bbox_bytes = json.dumps(bbox, indent=2).encode("utf-8")
        client.put_object(
            bucket_name=bucket,
            object_name="inputs/bbox.json",
            data=io.BytesIO(bbox_bytes),
            length=len(bbox_bytes),
            content_type="application/json",
        )
        context.log.info("Uploaded: inputs/bbox.json")
    except Exception as e:
        context.log.error(f"Failed to upload bbox.json: {e}")
        raise
    
    # Upload fields.geojson
    try:
        fields_bytes = json.dumps(fields_geojson, indent=2).encode("utf-8")
        client.put_object(
            bucket_name=bucket,
            object_name="inputs/fields.geojson",
            data=io.BytesIO(fields_bytes),
            length=len(fields_bytes),
            content_type="application/geo+json",
        )
        context.log.info("Uploaded: inputs/fields.geojson")
    except Exception as e:
        context.log.error(f"Failed to upload fields.geojson: {e}")
        raise
    
    context.log.info(
        f"Successfully initialized {len(fields_data)} fields "
        f"from configuration file"
    )
    
    return {
        "config_path": config_path,
        "bbox": bbox,
        "num_fields": len(fields_data),
        "crop_distribution": crop_counts,
        "fields": [
            {
                "id": f["id"],
                "crop_type": f["crop_type"],
                "planting_date": f["planting_date"]
            }
            for f in fields_data
        ],
    }