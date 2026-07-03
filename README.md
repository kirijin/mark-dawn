# Скачать и сделать исполняемым
curl -fsSL https://raw.githubusercontent.com/kirijin/mark-dawn/main/mark-dawn.sh -o mark-dawn
chmod +x mark-dawn

# Запустить
./mark-dawn start

# Проверить логи
./mark-dawn logs

# Конвертировать один файл
./mark-dawn convert ~/Downloads/document.pdf

# Установить автозапуск
./mark-dawn install-systemd
