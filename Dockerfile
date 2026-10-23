# SPDX-FileCopyrightText: 2026 kirijin <avel.ronin@gmail.com>
# SPDX-License-Identifier: MIT

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /tmp/requirements.txt

COPY convert_pdf.py /usr/local/bin/
COPY docx_styler.py /usr/local/bin/
COPY watcher.py /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/*.py /usr/local/bin/*.sh

# Create a non-root runtime user and pre-create writable dirs.
RUN groupadd -r markdawn && useradd -r -g markdawn -d /home/markdawn -m markdawn \
    && mkdir -p /data/Inbox /data/Research /data/Inbox_Failed /workspace/tmp \
    && chown -R markdawn:markdawn /data /workspace

WORKDIR /workspace

# Pipeline defaults — launchers override these with their own -e flags, but a
# bare `docker run <image> watcher` must also watch/write the mounted dirs.
ENV MARK_DAWN_INBOX_DIR=/data/Inbox \
    MARK_DAWN_OUT_DIR=/data/Research \
    MARK_DAWN_FAILED_DIR=/data/Inbox_Failed

LABEL org.opencontainers.image.title="mark-dawn" \
      org.opencontainers.image.description="Universal Document to Markdown Pipeline" \
      org.opencontainers.image.source="https://github.com/kirijin/mark-dawn" \
      org.opencontainers.image.licenses="MIT"

USER markdawn
RUN mkdir -p /workspace/tmp && chmod 700 /workspace/tmp 2>/dev/null || true
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["watcher"]