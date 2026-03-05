FROM python:3.11-slim

# Install torch CPU-only first from PyTorch index,
# then everything else from default PyPI.
RUN pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu \
    && pip install --no-cache-dir \
    sentence-transformers \
    langchain-text-splitters \
    pymilvus \
    requests \
    beautifulsoup4 \
    numpy

COPY etl_pipeline.py /app/etl_pipeline.py
WORKDIR /app

CMD ["python", "etl_pipeline.py"]
