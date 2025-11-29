# Agricultural Monitoring Pipeline with Dagster

A Dagster deployment on Kubernetes for monitoring agricultural fields using simulated NDVI satellite data and real weather information.

## Overview

This project implements a data orchestration pipeline for agricultural monitoring:

- Daily partitioned assets with temporal dependencies between partitions
- Geospatial processing with bounding boxes and field polygons
- Integration with NASA POWER API for real weather data (temperature, precipitation, solar radiation)
- Field filtering based on planting dates (no processing before crop is planted)
- S3-compatible storage (MinIO) for all inputs and outputs
- Complete Kubernetes deployment via Terraform (IaC)

## Deployment Options

This project supports three deployment approaches:

1. **Kubernetes with Terraform (Recommended)**: Full production setup with PostgreSQL, MinIO, complete Dagster deployment on K8s
2. **Docker Compose**: Simplified local development setup (MinIO + Dagster only, no K8s required)
3. **Local Python**: Development mode with `dagster dev` (requires manual MinIO/PostgreSQL setup)

This README primarily covers option 1 (Kubernetes). For Docker Compose, see the Development section.

## Prerequisites

### For Kubernetes Deployment (Recommended)

**Required Software:**
- Docker (with Kubernetes enabled) or minikube/kind
- Terraform >= 1.0
- kubectl configured and connected to your cluster
- Git

### For Docker Compose (Alternative)

**Required Software:**
- Docker and Docker Compose
- Git
- Python 3.9+ (optional, for local code changes)

**System Requirements:**
- 8 GB RAM minimum (16 GB recommended)
- 4 CPU cores
- 20 GB free disk space

**Verify your environment:**

```bash
docker --version
kubectl cluster-info
terraform --version
kubectl config current-context
```

For Docker Desktop, enable Kubernetes in Settings > Kubernetes > Enable Kubernetes.

## Quick Start

### 1. Clone and Build

```bash
git clone https://github.com/FDiDio/daily-geoprocessing-pipeline.git

# Build Docker image
docker build -t agricultural-pipeline:latest .
```

**Important:** The image must be available in your Kubernetes cluster:
- **Docker Desktop**: Image is automatically available
- **minikube**: Run `eval $(minikube docker-env)` before building
- **kind**: Run `kind load docker-image agricultural-pipeline:latest`

### 2. Deploy with Terraform

```bash
cd terraform

# Initialize Terraform
terraform init

# Review the plan (optional)
terraform plan

# Apply infrastructure
terraform apply
```

Type `yes` when prompted. This creates:
- Namespace: `agricultural-pipeline`
- 5 Deployments: PostgreSQL, MinIO, Dagster webserver, daemon, code location
- RBAC resources for Kubernetes job launching
- Secrets and ConfigMaps for configuration

### 3. Wait for Services

```bash
# Wait for all pods to be ready (2-3 minutes)
kubectl wait --for=condition=ready pod --all -n agricultural-pipeline --timeout=300s

# Check status
kubectl get pods -n agricultural-pipeline
```

All pods should show `Running` with `1/1` ready.

### 4. Access Dagster UI

Open your browser to: http://localhost:3000

You should see three assets:
- `init_inputs`
- `raw_satellite_raster`
- `field_daily_metrics`

## Project Structure

```
dagster_project/
├── config/
│   └── fields.yaml              # Field configuration (bbox, polygons, planting dates)
│
├── dagster_project/
│   ├── assets/
│   │   ├── init_inputs.py       # Load config and upload to MinIO
│   │   ├── raw_satellite.py     # Generate NDVI raster with NASA weather
│   │   └── field_processing.py  # Calculate per-field metrics
│   ├── resources/
│   │   └── minio_resource.py    # MinIO S3 client
│   └── definitions.py           # Dagster definitions
│
├── terraform/
│   ├── main.tf                  # Provider config, namespace
│   ├── variables.tf             # Customizable variables
│   ├── minio.tf                 # MinIO deployment
│   └── dagster.tf               # Dagster deployment
│
├── Dockerfile                   # Multi-stage Docker build
└── README.md
```

## Architecture

### System Components

```
Kubernetes Cluster (namespace: agricultural-pipeline)
│
├── Dagster Webserver (UI/API) - Port 3000
├── Dagster Daemon (Scheduler)
├── Dagster Code Server (gRPC) - Port 4000
├── PostgreSQL (Metadata) - Port 5432
└── MinIO (S3 Storage) - Port 9000
    │
    └── External: NASA POWER API (Weather Data)
```

### Data Flow

1. User triggers asset materialization in Dagster UI
2. Dagster Daemon launches Kubernetes job with asset code
3. Asset reads configuration from MinIO (bbox, fields)
4. Asset fetches weather data from NASA POWER API
5. Asset generates NDVI raster (influenced by weather + previous day)
6. Asset calculates per-field metrics (filtered by planting date)
7. Results written to MinIO as Parquet files
8. Metadata stored in PostgreSQL

### Partition Dependencies

Assets have strict temporal dependencies:

```
Day 1 (2024-01-01):
  raw_satellite_raster[2024-01-01] → No previous day, generates base NDVI
  field_daily_metrics[2024-01-01]  → Depends on raster[2024-01-01]

Day 2 (2024-01-02):
  raw_satellite_raster[2024-01-02] → Depends on raster[2024-01-01]
  field_daily_metrics[2024-01-02]  → Depends on raster[2024-01-02] + metrics[2024-01-01]

Day N:
  raw_satellite_raster[N] → Depends on raster[N-1]
  field_daily_metrics[N]  → Depends on raster[N] + metrics[N-1]
```

You must materialize partitions in chronological order.

## Dagster Assets

### Asset 1: init_inputs

**Purpose:** Load field configuration and upload to MinIO

**Type:** Non-partitioned (runs once)

**Processing:**
1. Load `config/fields.yaml`
2. Validate bounding box coordinates
3. Validate field polygons and planting dates
4. Convert to GeoJSON format
5. Upload to MinIO: `inputs/bbox.json` and `inputs/fields.geojson`

### Asset 2: raw_satellite_raster

**Purpose:** Generate NDVI satellite raster with temporal continuity

**Partitions:** Daily (starting 2024-01-01)

**Dependencies:**
- Previous day's NDVI raster (except first partition)
- Bounding box from MinIO
- Real weather data from NASA POWER API

**Processing:**
1. Load previous day's raster (if exists)
2. Fetch weather data: temperature, precipitation, solar radiation
3. Calculate weather influence on vegetation
4. Generate 100x100 NDVI grid:
   - First partition: base NDVI from seasonal phenology
   - Subsequent: 70% previous day + 30% weather influence
5. Add spatial heterogeneity and noise

**Output:** `raw_raster/YYYY-MM-DD/raster.csv`

### Asset 3: field_daily_metrics

**Purpose:** Calculate per-field agricultural metrics

**Partitions:** Daily (starting 2024-01-01)

**Dependencies:**
- Current day's NDVI raster
- Previous day's field metrics (for cumulative tracking)
- Field definitions from MinIO

**Processing:**
1. Load current raster and previous metrics
2. For each field:
   - **Check planting date:** Skip if `partition_date < planting_date`
   - Extract NDVI statistics for field polygon
   - Calculate: rainfall, soil moisture, crop stress
   - Accumulate cumulative stress from previous day
3. Save results as Parquet

**Output Schema:**
- `field_id`, `date`, `crop_type`
- `ndvi_mean`, `rainfall_mm`, `soil_moisture`
- `crop_stress_index`, `cumulative_stress_index`

**Output:** `field_metrics/YYYY-MM-DD/field_metrics.parquet`

**Planting Date Logic:**

The asset filters fields based on their planting dates. For example:
- Field A: planted 2024-03-10
- Field B: planted 2024-04-15

On partition 2024-03-15:
- Field A is processed (planted 5 days ago)
- Field B is skipped (not planted yet)

This ensures metrics only represent crops that actually exist.

## Configuration

### Fields Configuration (config/fields.yaml)

```yaml
bbox:
  xmin: 5.735   # West longitude
  ymin: 49.447  # South latitude
  xmax: 6.531   # East longitude
  ymax: 50.182  # North latitude

fields:
  - id: F001
    crop_type: wheat
    planting_date: "2024-03-10"
    polygon:
      - [5.90, 49.85]
      - [6.00, 49.85]
      - [6.00, 49.95]
      - [5.90, 49.95]
      - [5.90, 49.85]  # Must close the polygon
  
  - id: F002
    crop_type: corn
    planting_date: "2024-04-15"
    polygon:
      - [6.05, 49.85]
      # ... coordinates
```

**Customization:** Edit this file to add or modify fields. The pipeline automatically adapts to any number of fields.

### Terraform Variables (terraform/variables.tf)

```hcl
variable "kube_context" {
  default = "docker-desktop"  # or "minikube", "kind-kind"
}

variable "minio_root_user" {
  default = "minioadmin"
}

variable "minio_root_password" {
  default = "minioadmin"
}

variable "dagster_image" {
  default = "agricultural-pipeline:latest"
}
```

Modify these in `terraform/variables.tf` or pass via command line:

```bash
terraform apply -var="kube_context=minikube"
```

## Materializing Assets

### Step 1: Initialize Inputs

In the Dagster UI:
1. Navigate to Assets
2. Select `init_inputs`
3. Click "Materialize"

This loads the configuration and uploads it to MinIO.

### Step 2: Materialize Partitions

Option A - Single Partition:
1. Select `raw_satellite_raster` or `field_daily_metrics`
2. Click "Materialize"
3. Choose partition: e.g., `2024-01-01`
4. Click "Launch Run"

Option B - Multiple Partitions (recommended):
1. Select `field_daily_metrics` (will auto-materialize dependencies)
2. Click "Materialize"
3. Select partition range: `2024-01-01` to `2024-01-31`
4. Click "Launch Run"

The pipeline will materialize partitions in chronological order, respecting dependencies.

### Step 3: Monitor Progress

- View run status in the Runs tab
- Check logs for each asset
- Monitor resource usage: `kubectl top pods -n agricultural-pipeline`

## Verification

### 1. Check Pods

```bash
kubectl get pods -n agricultural-pipeline
```

All pods should be `Running` with `1/1` ready.

### 2. Verify MinIO Contents

```bash
# Port-forward MinIO
kubectl port-forward svc/minio 9000:9000 -n agricultural-pipeline

# Install MinIO client
brew install minio/stable/mc  # or download from min.io

# Configure alias
mc alias set local http://localhost:9000 minioadmin minioadmin

# List bucket contents
mc ls local/dagster-bucket/
mc ls local/dagster-bucket/inputs/
mc ls local/dagster-bucket/raw_raster/
mc ls local/dagster-bucket/field_metrics/
```

Expected structure:
```
dagster-bucket/
├── inputs/
│   ├── bbox.json
│   └── fields.geojson
├── raw_raster/
│   ├── 2024-01-01/raster.csv
│   ├── 2024-01-02/raster.csv
│   └── ...
└── field_metrics/
    ├── 2024-01-01/field_metrics.parquet
    ├── 2024-01-02/field_metrics.parquet
    └── ...
```

### 3. Inspect Parquet Files

```bash
# Download a metrics file
mc cp local/dagster-bucket/field_metrics/2024-03-15/field_metrics.parquet .

# View with Python
python3 << EOF
import pandas as pd
df = pd.read_parquet('field_metrics.parquet')
print(df.head())
print(f"\nTotal fields processed: {len(df)}")
print(f"\nCrop types: {df['crop_type'].unique()}")
EOF
```

### 4. Check Run Logs

```bash
# View code location logs
kubectl logs -f deployment/dagster-code -n agricultural-pipeline

# Search for specific patterns
kubectl logs deployment/dagster-code -n agricultural-pipeline | grep "NASA"
kubectl logs deployment/dagster-code -n agricultural-pipeline | grep "planting_date"
```

Look for:
- "Fetching NASA POWER weather data"
- "Loaded previous day's raster"
- "Skipped X fields (not planted yet)"
- "Processed Y fields for partition"

## Troubleshooting

### Pods Not Starting

**Symptoms:** Pods stuck in `Pending` or `CrashLoopBackOff`

```bash
# Check pod status
kubectl get pods -n agricultural-pipeline

# Describe pod for events
kubectl describe pod <pod-name> -n agricultural-pipeline

# Check logs
kubectl logs <pod-name> -n agricultural-pipeline
```

Common issues:
- Insufficient resources: Reduce resource requests in `terraform/dagster.tf`
- Image pull error: Verify image is built and available in cluster
- Config errors: Check ConfigMaps and Secrets

### Dagster UI Shows "No Code Locations"

```bash
# Check code location is running
kubectl get pods -l app=dagster-code -n agricultural-pipeline

# Check code location logs
kubectl logs -f deployment/dagster-code -n agricultural-pipeline

# Restart webserver
kubectl rollout restart deployment/dagster-webserver -n agricultural-pipeline
```

### Asset Materialization Fails

Check run logs in Dagster UI (click on failed run).

Common errors:
1. **MinIO connection error:** Check minio pod is running
2. **NASA API timeout:** Check internet connectivity, API may be rate-limiting
3. **Previous partition missing:** Materialize partitions in chronological order
4. **Config file not found:** Verify `init_inputs` was materialized first

### MinIO Access Denied

```bash
# Verify MinIO is running
kubectl get pods -l app=minio -n agricultural-pipeline

# Check credentials in secret
kubectl get secret minio-credentials -n agricultural-pipeline -o yaml

# Test access
kubectl port-forward svc/minio 9000:9000 -n agricultural-pipeline
mc alias set test http://localhost:9000 minioadmin minioadmin
mc ls test/
```

### PostgreSQL Connection Error

```bash
# Check postgres is running
kubectl get pods -l app=postgres -n agricultural-pipeline

# Test connection from code pod
kubectl exec -it deployment/dagster-code -n agricultural-pipeline -- \
  psql postgresql://dagster:dagster_secure_password@postgres:5432/dagster -c "SELECT 1"
```

### Clean Restart

If issues persist:

```bash
# Destroy everything
cd terraform
terraform destroy

# Rebuild image
cd ..
docker build -t agricultural-pipeline:latest .

# Redeploy
cd terraform
terraform apply
```

## Development

### Option 1: Docker Compose (Simplest)

The quickest way to run locally without Kubernetes:

```bash
# Start MinIO and Dagster
docker-compose up

# Access Dagster UI at http://localhost:3000
# MinIO Console at http://localhost:9001 (admin/admin123)
```

**Note:** Docker Compose setup includes:
- MinIO for S3 storage
- Dagster webserver only (no daemon, no job isolation)
- Suitable for development and testing, not production

**Limitations:**
- No PostgreSQL (uses in-memory storage)
- No run isolation (runs execute in webserver process)
- No scheduler daemon
- Code changes require rebuilding image: `docker-compose up --build`

### Option 2: Local Development (Full Control)

For faster iteration without Docker:

```bash
# Install dependencies
pip install -r requirements.txt

# Set environment variables
export MINIO_ENDPOINT=localhost:9000
export MINIO_ACCESS_KEY=minioadmin
export MINIO_SECRET_KEY=minioadmin

# Run local MinIO (via Docker or standalone)
docker run -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

# In another terminal, run Dagster dev server
dagster dev -m dagster_project

# Access at http://localhost:3000
```

### Option 3: Kubernetes Development

For development on the full K8s stack:

1. Make code changes in `dagster_project/assets/`
2. Rebuild Docker image: `docker build -t agricultural-pipeline:latest .`
3. Restart code location: `kubectl rollout restart deployment/dagster-code -n agricultural-pipeline`
4. Refresh Dagster UI (changes appear in ~30 seconds)

### Adding New Assets

1. Create new file in `dagster_project/assets/`
2. Define asset with `@asset` decorator
3. Import in `dagster_project/definitions.py`
4. Rebuild and redeploy (method depends on deployment option above)

## AI Tools Used

This project used partial assistance from **ChatGPT (OpenAI)** for specific implementation details, such as refining function logic and ensuring correct syntax for some libraries.
