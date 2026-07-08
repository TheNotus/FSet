# FSet — первоначальная настройка сервера

Скрипт для базовой настройки VDS: обновление системы, SSH (порт, отключение root, опционально вход только по ключу), пользователь с sudo, фаервол, Fail2Ban.

**Запуск (одной командой с любого сервера):**

```bash
curl -fsSL "https://raw.githubusercontent.com/TheNotus/FSet/main/server-setup.sh" | sudo bash
```
