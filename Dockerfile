FROM docker.io/jbarlow83/ocrmypdf:v17

RUN apt-get update && apt-get install -y --no-install-recommends \
    tesseract-ocr-eng \
    tesseract-ocr-rus \
    tesseract-ocr-fra \
    tesseract-ocr-deu \
    tesseract-ocr-chi-sim \
    tesseract-ocr-jpn \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/markdawn
ENV PATH="/opt/markdawn/bin:$PATH"

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    pymupdf4llm \
    "markitdown[all]" \
    watchdog \
    ocrmypdf

COPY convert_pdf.py /usr/local/bin/
COPY watcher.py /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/*.py /usr/local/bin/*.sh

WORKDIR /workspace

LABEL org.opencontainers.image.title="mark-dawn" \
      org.opencontainers.image.description="Universal Document to Markdown Pipeline" \
      org.opencontainers.image.source="https://github.com/kirijin/mark-dawn" \
      org.opencontainers.image.licenses="MIT"

USER root
RUN mkdir -p /workspace/tmp && chmod -R 777 /workspace/tmp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["watcher"]
