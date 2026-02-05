# FSet — первоначальная настройка сервера

Скрипт для базовой настройки VDS: обновление системы, SSH, пользователь с sudo, фаервол, Fail2Ban.

## Запуск с любого сервера (скрипт на GitHub)

После того как вы загрузите репозиторий на GitHub:

1. Откройте репозиторий на GitHub.
2. Перейдите в нужную ветку (обычно `main` или `master`).
3. Откройте файл `server-setup.sh` и нажмите **Raw** — скопируйте URL из адресной строки.  
   Он будет вида:  
   `https://raw.githubusercontent.com/TheNotus/FSet/main/server-setup.sh`

На сервере выполните (подставьте свой URL):

```bash
curl -sSL "https://raw.githubusercontent.com/TheNotus/FSet/main/server-setup.sh" -o server-setup.sh
chmod +x server-setup.sh
sudo ./server-setup.sh
```

Или одной строкой (скачать и сразу запустить):

```bash
curl -sSL "https://raw.githubusercontent.com/TheNotus/FSet/main/server-setup.sh" | sudo bash
```

> **Важно:** Запуск `curl ... | bash` выполняет код из интернета. Используйте только свой репозиторий или проверенный источник.