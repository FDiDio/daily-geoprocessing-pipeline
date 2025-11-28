# Hydrosat Dagster - Docker Image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY dagster_project/ ./dagster_project/
COPY config/ ./config/

# Create workspace configuration
RUN echo 'load_from:\n  - python_module: dagster_project' > workspace.yaml

# Expose Dagster webserver port (only for local debugging)
EXPOSE 3000

# Set environment variables
ENV DAGSTER_HOME=/opt/dagster/dagster_home
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

# Create Dagster home directory
RUN mkdir -p $DAGSTER_HOME

# Default command (used by dagster-code deployment)
CMD ["dagster", "api", "grpc", "-h", "0.0.0.0", "-p", "4000", "-m", "dagster_project"]
