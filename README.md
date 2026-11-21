# BattBar

Маленький значок в строке меню macOS для управления пределом зарядки через [batt](https://github.com/charlie0129/batt).

Показывает заряд батареи, держит постоянный предел, умеет разово дозарядить до 80% или 100% и напоминает поставить ноутбук на зарядку.

## Что умеет

- **Заряд в строке меню.** Пока идёт зарядка, рядом с процентом виден ⚡︎.
- **Держать всегда** 50, 60, 80 или 100%. Выше предела батарея не заряжается, а ноутбук работает от сети.
- **Один раз до 80% или до 100%.** Ноутбук дозаряжается до цели, потом предел сам возвращается к постоянному. Пока разовая зарядка идёт, на значке видно «→ 100».
- **Напоминание о зарядке.** Если ноутбук работает от батареи и заряд падает до 20 или 30%, значок мигает красным и звучит сигнал. Сигнал повторяется раз в 5 минут, пока не подключишь зарядку.

Заряд проверяется раз в 30 секунд и сразу, когда подключаешь или отключаешь зарядку. Процессор почти не нагружается, памяти уходит около 50 МБ.

## Что нужно

- Mac на Apple Silicon с macOS 13 или новее.
- Xcode или Command Line Tools: нужен `swiftc`.
- [batt](https://github.com/charlie0129/batt) с запущенной службой:

```bash
brew install batt
sudo brew services start batt
```

Встроенный предел зарядки macOS (Настройки → Аккумулятор) лучше выключить, чтобы он не спорил с batt.

## Сборка и запуск

```bash
./build.sh
```

Скрипт собирает `~/Applications/BattBar.app`, подписывает её локально и запускает. Путь к batt задан в `main.swift` (`/opt/homebrew/bin/batt`).

Проверить напоминание сразу, не дожидаясь низкого заряда:

```bash
~/Applications/BattBar.app/Contents/MacOS/BattBar --test-alert
```

## Автозапуск

Создай файл `~/Library/LaunchAgents/local.battbar.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.battbar</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-g</string><string>/Users/YOU/Applications/BattBar.app</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

Замени `YOU` на имя своей учётной записи и загрузи файл:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.battbar.plist
```

## Если значка не видно

На MacBook с вырезом камеры лишние значки прячутся за вырезом. Можно убрать часть других значков или задать BattBar место ближе к часам:

```bash
defaults write local.battbar "NSStatusItem Preferred Position Item-0" -float 260
```

После этого перезапусти BattBar.

## Важно

Пока Mac выключен, batt не работает, и на зарядке батарея может зарядиться до 100%. В сне предел держится.

## Лицензия

MIT
