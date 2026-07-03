FROM docker.io/jbarlow83/ocrmypdf:v17

# Устанавливаем языковые пакеты Tesseract + python3-pip + venv
# ISO 639-2: eng, rus, fra (French), deu (German), chi_sim (Chinese Simplified), jpn (Japanese)
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

# Создаём изолированное виртуальное окружение
RUN python3 -m venv /opt/markdawn
ENV PATH="/opt/markdawn/bin:$PATH"

# Обновляем pip и ставим Python-инструменты
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
    pymupdf4llm \
    "markitdown[all]" \
    watchdog \
    ocrmypdf

# Копируем скрипты
COPY convert_pdf.py /usr/local/bin/
COPY watcher.py /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/*.py /usr/local/bin/*.sh

WORKDIR /workspace

LABEL org.opencontainers.image.title="mark-dawn" \
      org.opencontainers.image.description="Universal Document to Markdown Pipeline" \
      org.opencontainers.image.source="https://github.com/kirijin/mark-dawn" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["watcher"]
