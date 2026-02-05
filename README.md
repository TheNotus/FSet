# FSet — первоначальная настройка сервера

Скрипт для базовой настройки VDS: обновление системы, SSH, пользователь с sudo, фаервол, Fail2Ban.

## Запуск с любого сервера (скрипт на GitHub)

После того как вы загрузите репозиторий на GitHub:

1. Откройте репозиторий на GitHub.
2. Перейдите в нужную ветку (обычно `main` или `master`).
3. Откройте файл `server-setup.sh` и нажмите **Raw** — скопируйте URL из адресной строки.  
   Он будет вида:  
   `https://raw.githubusercontent.com/ВАШ_ЛОГИН/ВАШ_РЕПОЗИТОРИЙ/main/server-setup.sh`

На сервере выполните (подставьте свой URL):

```bash
curl -sSL "https://raw.githubusercontent.com/ВАШ_ЛОГИН/ВАШ_РЕПОЗИТОРИЙ/main/server-setup.sh" -o server-setup.sh
chmod +x server-setup.sh
sudo ./server-setup.sh
```

Или одной строкой (скачать и сразу запустить):

```bash
curl -sSL "https://raw.githubusercontent.com/ВАШ_ЛОГИН/ВАШ_РЕПОЗИТОРИЙ/main/server-setup.sh" | sudo bash
```

> **Важно:** Запуск `curl ... | bash` выполняет код из интернета. Используйте только свой репозиторий или проверенный источник.

---

## Как выложить скрипт на GitHub

### Вариант 1: через сайт GitHub

1. Зайдите на [github.com](https://github.com), войдите в аккаунт.
2. **New repository** → имя, например `FSet` → **Create repository**.
3. **Add file** → **Upload files** → перетащите папку `FSet` (или файл `server-setup.sh`) → **Commit changes**.

Готовый raw-URL будет:  
`https://raw.githubusercontent.com/ВАШ_ЛОГИН/FSet/main/server-setup.sh`

### Вариант 2: через Git в терминале

```bash
cd d:\project\FSet
git init
git add server-setup.sh README.md
git commit -m "Initial: server setup script"
git branch -M main
git remote add origin https://github.com/ВАШ_ЛОГИН/FSet.git
git push -u origin main
```

Подставьте свой логин и имя репозитория. Если репозиторий уже создан на GitHub, используйте его URL в `git remote add origin ...`.

---

## Что делает скрипт

- Обновление системы (apt/dnf/yum)
- Настройка SSH: порт по вашему выбору, отключение входа root
- Создание пользователя с правами sudo (пароль — сгенерировать или ввести)
- Фаервол: открыты только указанные порты (SSH + дополнительные)
- Fail2Ban: бан на 1 час после 3 неудачных попыток входа за 10 минут

Запуск на сервере: `sudo ./server-setup.sh`
