#!/bin/bash
# install_bot_youtrack.sh - Установка Telegram-YouTrack бота на Debian 12

set -e  # Завершить при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен запускаться с правами root"
    exit 1
fi

# Запрашиваем данные у пользователя
print_info "Для работы бота нужны следующие данные:"
read -p "Введите доменное имя (например: bot.example.com): " DOMAIN
read -p "Введите email для SSL сертификата: " SSL_EMAIL
read -p "Введите Telegram Bot Token (от @BotFather): " TELEGRAM_TOKEN
read -p "Введите Telegram Admin ID (ваш цифровой ID в Telegram): " TELEGRAM_ADMIN_ID
read -p "Введите YouTrack Token: " YOUTRACK_TOKEN

# Выбор режима работы
echo ""
print_info "Выберите режим работы бота:"
echo "1) Polling (рекомендуется для тестирования)"
echo "2) Webhook (рекомендуется для продакшена)"
read -p "Выберите режим (1 или 2): " BOT_MODE

if [ "$BOT_MODE" = "1" ]; then
    USE_WEBHOOK=false
    BOT_MODE_NAME="Polling"
    print_status "Выбран режим: Polling"
elif [ "$BOT_MODE" = "2" ]; then
    USE_WEBHOOK=true
    BOT_MODE_NAME="Webhook"
    print_status "Выбран режим: Webhook"
else
    print_warning "Неверный выбор. Используется режим по умолчанию: Polling"
    USE_WEBHOOK=false
    BOT_MODE_NAME="Polling"
fi

# Переменные
APP_NAME="telegram-youtrack"
APP_DIR="/opt/$APP_NAME"
USER_NAME="mbsup"
SERVICE_NAME="mbsup-bot"
LOG_DIR="/var/log/$APP_NAME"
DATA_DIR="$APP_DIR/data"
CONFIG_DIR="$APP_DIR/config"

print_status "Установка улучшенного Telegram-YouTrack бота с поддержкой reply и кнопок меню"
print_status "Домен: $DOMAIN"
print_status "Директория: $APP_DIR"
print_status "Режим работы: $BOT_MODE_NAME"

# 1. Обновление системы и установка базовых пакетов
print_status "1. Обновление системы и установка базовых пакетов..."
apt update
apt upgrade -y

# 2. Установка Nginx и Certbot
print_status "2. Установка Nginx и Certbot..."
apt install -y nginx certbot python3-certbot-nginx

# 3. Настройка Nginx и получение SSL сертификата
print_status "3. Настройка Nginx и получение SSL сертификата..."

# Создаем базовый конфиг Nginx
cat > "/etc/nginx/sites-available/$DOMAIN" << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # Редирект с www на без www
    if (\$host ~ ^www\.(.+)\$) {
        return 301 http://\$1\$request_uri;
    }
    
    location / {
        return 200 "Nginx работает. Сертификат будет настроен позже.\n";
        add_header Content-Type text/plain;
    }
    
    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
EOF

# Активируем сайт
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
nginx -t
systemctl restart nginx

# Получаем SSL сертификат
print_status "Получение SSL сертификата для $DOMAIN..."
if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect; then
    print_status "✅ SSL сертификат успешно получен и настроен"
else
    print_warning "❌ Не удалось получить SSL сертификат автоматически"
    print_warning "Вы можете получить его вручную позже с помощью:"
    print_warning "certbot --nginx -d $DOMAIN"
    print_warning "Продолжаем установку без SSL..."
fi

# 4. Установка остальных зависимостей
print_status "4. Установка системных зависимостей..."
apt install -y \
    python3-pip \
    python3-venv \
    python3-dev \
    git \
    curl \
    wget \
    nano \
    htop \
    fail2ban \
    ufw \
    supervisor \
    systemd \
    apache2-utils  # Для htpasswd

# 5. Создание пользователя и директорий
print_status "5. Создание пользователя и директорий..."
if ! id "$USER_NAME" &>/dev/null; then
    useradd -r -m -d "$APP_DIR" -s /bin/bash "$USER_NAME"
    print_status "Пользователь $USER_NAME создан"
else
    print_warning "Пользователь $USER_NAME уже существует"
fi

# Создание структуры директорий
mkdir -p "$APP_DIR/app" "$LOG_DIR" "$DATA_DIR" "$CONFIG_DIR" "$DATA_DIR/uploads"
chown -R "$USER_NAME:$USER_NAME" "$APP_DIR" "$LOG_DIR"
chmod 755 "$APP_DIR" "$LOG_DIR"

# 6. Создание файлов приложения
print_status "6. Создание файлов приложения..."

# Создаем dialog_manager.py
sudo -u "$USER_NAME" cat > "$APP_DIR/app/dialog_manager.py" << 'EOF'
#!/usr/bin/env python3
"""
Модуль управления диалогами и контекстом
"""

import json
import logging
import re
from pathlib import Path
from typing import Dict, Optional, List
from datetime import datetime

logger = logging.getLogger(__name__)

class DialogManager:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.dialogs_file = data_dir / 'active_dialogs.json'
        self.issues_file = data_dir / 'tracked_issues.json'
        
        # Создаем директорию если её нет
        self.data_dir.mkdir(exist_ok=True)
    
    def _load_dialogs(self) -> Dict:
        """Загружает данные о диалогах"""
        try:
            if self.dialogs_file.exists():
                with open(self.dialogs_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            return {}
        except Exception as e:
            logger.error(f"Ошибка загрузки диалогов: {e}")
            return {}
    
    def _save_dialogs(self, data: Dict):
        """Сохраняет данные о диалогах"""
        try:
            with open(self.dialogs_file, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Ошибка сохранения диалогов: {e}")
    
    def _load_issues(self) -> Dict:
        """Загружает данные о задачах"""
        try:
            if self.issues_file.exists():
                with open(self.issues_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            return {}
        except Exception as e:
            logger.error(f"Ошибка загрузки задач: {e}")
            return {}
    
    def get_active_dialog(self, chat_id: int) -> Optional[Dict]:
        """Получает активный диалог для чата"""
        dialogs = self._load_dialogs()
        dialog_data = dialogs.get(str(chat_id))
        
        # Проверяем, не устарел ли диалог (более 1 часа)
        if dialog_data:
            last_activity = datetime.fromisoformat(dialog_data['last_activity'])
            if (datetime.now() - last_activity).total_seconds() > 3600:  # 1 час
                logger.info(f"Диалог для чата {chat_id} устарел, закрываем")
                self.close_dialog(chat_id)
                return None
        
        return dialog_data
    
    def start_new_dialog(self, chat_id: int, issue_id: str, issue_data: Dict = None):
        """Начинает новый диалог по задаче"""
        dialogs = self._load_dialogs()
        
        dialogs[str(chat_id)] = {
            'active_issue': issue_id,
            'started_at': datetime.now().isoformat(),
            'last_activity': datetime.now().isoformat(),
            'message_count': 1,
            'issue_data': issue_data or {}
        }
        
        self._save_dialogs(dialogs)
        logger.info(f"Начат новый диалог для чата {chat_id} по задаче {issue_id}")
    
    def update_dialog_activity(self, chat_id: int):
        """Обновляет время последней активности в диалоге"""
        dialogs = self._load_dialogs()
        
        if str(chat_id) in dialogs:
            dialogs[str(chat_id)]['last_activity'] = datetime.now().isoformat()
            dialogs[str(chat_id)]['message_count'] += 1
            self._save_dialogs(dialogs)
    
    def close_dialog(self, chat_id: int):
        """Закрывает активный диалог"""
        dialogs = self._load_dialogs()
        
        if str(chat_id) in dialogs:
            issue_id = dialogs[str(chat_id)]['active_issue']
            del dialogs[str(chat_id)]
            self._save_dialogs(dialogs)
            logger.info(f"Диалог для чата {chat_id} по задаче {issue_id} закрыт")
            return True
        return False
    
    def get_user_issues(self, chat_id: int, limit: int = 10) -> List[Dict]:
        """Получает все задачи пользователя"""
        issues = self._load_issues()
        user_issues = []
        
        for issue_id, issue_data in issues.items():
            if issue_data.get('chat_id') == chat_id:
                user_issues.append({
                    'id': issue_id,
                    'created_at': issue_data.get('created_at', ''),
                    'summary': issue_data.get('summary', 'Без названия'),
                    'active': True
                })
        
        # Сортируем по дате создания (новые первые)
        user_issues.sort(key=lambda x: x['created_at'], reverse=True)
        
        return user_issues[:limit]
    
    def find_issue_for_message(self, chat_id: int, message_text: str) -> Optional[str]:
        """
        Определяет, к какой задаче относится сообщение
        
        Алгоритм:
        1. Если есть активный диалог - возвращаем его
        2. Если сообщение содержит номер задачи (MST-1) - возвращаем её
        3. Если есть только одна активная задача - возвращаем её
        4. Иначе создаем новую
        """
        # 1. Проверяем активный диалог
        active_dialog = self.get_active_dialog(chat_id)
        if active_dialog:
            logger.info(f"Используем активный диалог: {active_dialog['active_issue']}")
            return active_dialog['active_issue']
        
        # 2. Ищем номер задачи в сообщении
        issue_pattern = r'(MST-\d+|TS-\d+|DEMO-\d+)'
        matches = re.findall(issue_pattern, message_text, re.IGNORECASE)
        
        if matches:
            issue_id = matches[0].upper()
            
            # Проверяем, существует ли задача
            issues = self._load_issues()
            if issue_id in issues and issues[issue_id].get('chat_id') == chat_id:
                logger.info(f"Найден номер задачи в сообщении: {issue_id}")
                return issue_id
        
        # 3. Получаем все задачи пользователя
        user_issues = self.get_user_issues(chat_id)
        
        if len(user_issues) == 1:
            # Если только одна задача - используем её
            logger.info(f"У пользователя одна задача: {user_issues[0]['id']}")
            return user_issues[0]['id']
        elif len(user_issues) > 1:
            # Если несколько задач - просим уточнить
            logger.info(f"У пользователя {len(user_issues)} задач, нужен выбор")
            return None
        
        # 4. Нет задач - создаем новую
        logger.info("У пользователя нет задач, создаем новую")
        return None
    
    def create_issue_reference(self, chat_id: int, issue_id: str, message_id: int):
        """Создает связь между сообщением и задачей"""
        dialogs = self._load_dialogs()
        
        if str(chat_id) not in dialogs:
            dialogs[str(chat_id)] = {}
        
        if 'message_references' not in dialogs[str(chat_id)]:
            dialogs[str(chat_id)]['message_references'] = {}
        
        dialogs[str(chat_id)]['message_references'][str(message_id)] = issue_id
        self._save_dialogs(dialogs)
    
    def get_issue_from_reply(self, chat_id: int, reply_to_message_id: int) -> Optional[str]:
        """Получает задачу по reply к сообщению"""
        dialogs = self._load_dialogs()
        
        if str(chat_id) in dialogs:
            references = dialogs[str(chat_id)].get('message_references', {})
            issue_id = references.get(str(reply_to_message_id))
            
            if issue_id:
                logger.info(f"Найдена задача по reply: {issue_id}")
                return issue_id
        
        return None
    
    def get_dialog_stats(self) -> Dict:
        """Получает статистику по диалогам"""
        dialogs = self._load_dialogs()
        issues = self._load_issues()
        
        active_dialogs = len(dialogs)
        total_issues = len(issues)
        
        # Группируем по чатам
        chats_with_dialogs = {}
        for chat_id, dialog_data in dialogs.items():
            chats_with_dialogs[chat_id] = {
                'issue': dialog_data.get('active_issue'),
                'messages': dialog_data.get('message_count', 0),
                'last_activity': dialog_data.get('last_activity')
            }
        
        return {
            'active_dialogs': active_dialogs,
            'total_issues': total_issues,
            'chats_with_dialogs': chats_with_dialogs
        }
EOF

# Создаем bot.py с поддержкой webhook и polling
print_status "Создание bot.py с поддержкой webhook и polling..."
sudo -u "$USER_NAME" cat > "$APP_DIR/app/bot.py" << 'EOF'
#!/usr/bin/env python3
"""
Telegram Bot модуль с поддержкой reply к существующим задачам и кнопками меню
Поддерживает оба режима: Polling и Webhook
"""

import asyncio
import logging
import json
import re
from pathlib import Path
from telegram import Update, InlineKeyboardMarkup, InlineKeyboardButton
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import NetworkError, TimedOut
import ssl

logger = logging.getLogger(__name__)

class TelegramBot:
    def __init__(self, telegram_token: str, youtrack_client, config: dict):
        self.token = telegram_token
        self.youtrack = youtrack_client
        self.config = config
        self.application = None
        self.data_dir = Path('/opt/telegram-youtrack/data')
        self.uploads_dir = self.data_dir / 'uploads'
        
        # Режим работы
        self.use_webhook = config.get('server', {}).get('use_webhook', False)
        self.webhook_port = config.get('server', {}).get('port', 8443)
        self.webhook_host = config.get('server', {}).get('host', '0.0.0.0')
        
        # Инициализируем менеджер диалогов
        from app.dialog_manager import DialogManager
        self.dialog_manager = DialogManager(self.data_dir)
        
        # Создаем директории если их нет
        self.data_dir.mkdir(exist_ok=True)
        self.uploads_dir.mkdir(exist_ok=True)
        
        # Настройки файлов
        self.max_file_size = config.get('files', {}).get('max_size_mb', 50) * 1024 * 1024
        self.cleanup_after_upload = config.get('files', {}).get('cleanup_after_upload', True)
    
    async def start(self):
        """Запуск Telegram бота"""
        try:
            # Создаем application с контекстом
            self.application = Application.builder().token(self.token).build()
            
            # Сохраняем ссылку на себя в bot_data для доступа из callback-обработчиков
            self.application.bot_data['bot_instance'] = self
            
            # Регистрируем обработчики команд
            self.application.add_handler(CommandHandler("start", self.handle_start))
            self.application.add_handler(CommandHandler("help", self.handle_help))
            self.application.add_handler(CommandHandler("status", self.handle_status))
            self.application.add_handler(CommandHandler("myissues", self.handle_myissues))
            self.application.add_handler(CommandHandler("close", self.handle_close))
            self.application.add_handler(CommandHandler("continue", self.handle_continue))
            self.application.add_handler(CommandHandler("stats", self.handle_stats))
            
            # Добавляем обработчик callback-кнопок
            self.setup_callback_handler()
            
            # Обработчики сообщений
            self.application.add_handler(MessageHandler(
                filters.TEXT & ~filters.COMMAND & ~filters.CAPTION,
                self.handle_message
            ))
            
            # Обработчики файлов
            self.application.add_handler(MessageHandler(
                filters.Document.ALL,
                self.handle_document
            ))
            
            self.application.add_handler(MessageHandler(
                filters.PHOTO,
                self.handle_photo
            ))
            
            self.application.add_handler(MessageHandler(
                filters.VIDEO,
                self.handle_video
            ))
            
            self.application.add_handler(MessageHandler(
                filters.AUDIO | filters.VOICE,
                self.handle_audio
            ))
            
            # Обработчик ошибок
            self.application.add_error_handler(self.error_handler)
            
            # Настраиваем меню команд
            await self.setup_menu_commands()
            
            # Запускаем в зависимости от режима
            if self.use_webhook:
                await self.start_webhook()
            else:
                await self.start_polling()
            
        except Exception as e:
            logger.error(f"Ошибка при запуске бота: {e}", exc_info=True)
            raise
    
    async def start_polling(self):
        """Запуск в режиме polling"""
        logger.info("🤖 Запуск бота в режиме Polling...")
        
        await self.application.initialize()
        await self.application.start()
        
        await self.application.updater.start_polling(
            poll_interval=1.0,
            timeout=10,
            drop_pending_updates=True,
            allowed_updates=Update.ALL_TYPES
        )
        
        logger.info("✅ Telegram бот запущен в режиме Polling")
        logger.info("📎 Поддержка reply: включена")
        logger.info("💬 Система диалогов: активна")
        logger.info("📋 Кнопки меню: настроены")
        
        # Блокируем выполнение
        await asyncio.Event().wait()
    
    async def start_webhook(self):
        """Запуск в режиме webhook"""
        logger.info("🤖 Запуск бота в режиме Webhook...")
        
        domain = self.config.get('server', {}).get('domain', '')
        if not domain:
            logger.error("❌ Для webhook режима необходимо указать domain в конфигурации")
            raise ValueError("Domain не указан для webhook режима")
        
        webhook_url = f"https://{domain}/webhook"
        
        await self.application.initialize()
        await self.application.start()
        
        # Получаем SSL сертификаты
        ssl_cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
        ssl_key = f"/etc/letsencrypt/live/{domain}/privkey.pem"
        
        if Path(ssl_cert).exists() and Path(ssl_key).exists():
            # Создаем SSL контекст
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(ssl_cert, ssl_key)
            
            # Настраиваем webhook
            await self.application.bot.set_webhook(
                url=webhook_url,
                certificate=open(ssl_cert, 'rb'),
                drop_pending_updates=True
            )
            
            # Запускаем webhook сервер
            await self.application.updater.start_webhook(
                listen=self.webhook_host,
                port=self.webhook_port,
                url_path='',
                webhook_url=webhook_url,
                ssl_context=context
            )
            
            logger.info(f"✅ Webhook настроен: {webhook_url}")
            logger.info(f"📡 Прослушивание: {self.webhook_host}:{self.webhook_port}")
        else:
            logger.error(f"❌ SSL сертификаты не найдены: {ssl_cert}")
            raise FileNotFoundError(f"SSL сертификаты не найдены: {ssl_cert}")
        
        logger.info("✅ Telegram бот запущен в режиме Webhook")
        logger.info("📎 Поддержка reply: включена")
        logger.info("💬 Система диалогов: активна")
        logger.info("📋 Кнопки меню: настроены")
        
        # Блокируем выполнение
        await asyncio.Event().wait()
    
    def setup_callback_handler(self):
        """Настраивает обработчик callback-кнопок"""
        try:
            from app.callback_handler import handle_callback_query
            
            # Создаем обертку для передачи bot_instance
            async def callback_wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
                # Передаем bot_instance в context
                if 'bot_instance' not in context.bot_data:
                    context.bot_data['bot_instance'] = self
                await handle_callback_query(update, context)
            
            self.application.add_handler(CallbackQueryHandler(callback_wrapper))
            logger.info("✅ Обработчик callback-кнопок настроен")
            
        except Exception as e:
            logger.error(f"Ошибка настройки callback-обработчика: {e}")
    
    async def setup_menu_commands(self):
        """Настраивает меню команд для бота"""
        try:
            commands = [
                ("start", "Начать работу"),
                ("help", "Показать справку"),
                ("status", "Статус системы"),
                ("myissues", "Мои задачи"),
                ("close", "Закрыть диалог"),
                ("continue", "Продолжить с задачей"),
                ("stats", "Статистика (админ)")
            ]
            
            await self.application.bot.set_my_commands(commands)
            logger.info("✅ Меню команд настроено")
            
        except Exception as e:
            logger.error(f"Ошибка настройки меню команд: {e}")
    
    async def handle_start(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка команды /start"""
        try:
            welcome_text = """👋 *Добро пожаловать в улучшенную службу поддержки!*

📋 *Новые возможности:*
• Ответьте (reply) на сообщение о задаче, чтобы добавить комментарий
• Укажите номер задачи в сообщении (MST-123)
• Используйте /myissues для просмотра ваших задач
• Используйте /continue MST-123 для работы с конкретной задачей
• Используйте /close для завершения текущего диалога

📎 *Можно прикреплять файлы:*
• Документы, фото, видео, аудио
• Максимальный размер: 50 МБ

💡 *Как это работает:*
1. Отправьте сообщение или файл
2. Бот создаст заявку или определит к какой задаче относится
3. Ответьте на любое сообщение бота для добавления комментария
4. Получайте уведомления о новых комментариях

_Мы готовы помочь!"""
            
            # Создаем клавиатуру с быстрыми командами
            keyboard = [
                [
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                    InlineKeyboardButton("📊 Статус", callback_data="menu_status")
                ],
                [
                    InlineKeyboardButton("❓ Помощь", callback_data="menu_help"),
                    InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text(welcome_text, reply_markup=reply_markup)
            
            user = update.effective_user
            logger.info(f"Пользователь {user.id} вызвал /start")
            
        except Exception as e:
            logger.error(f"Ошибка в handle_start: {e}", exc_info=True)
    
    async def handle_help(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка команды /help"""
        try:
            help_text = """📚 *Доступные команды:*

/start - Начать работу с ботом
/help - Показать эту справку
/status - Статус системы
/myissues - Мои задачи
/close - Закрыть текущий диалог
/continue MST-123 - Продолжить работу с задачей
/stats - Статистика системы

💬 *Работа с задачами:*
• Просто отправьте сообщение - бот создаст новую задачу
• Ответьте (reply) на сообщение бота - добавится комментарий
• Укажите номер задачи в сообщении (MST-123)
• Файлы прикрепляются к активной задаче

📨 *Уведомления:*
Вы будете получать уведомления о новых комментариях к вашим задачам."""
            
            # Добавляем кнопки быстрого доступа
            keyboard = [
                [
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                    InlineKeyboardButton("📊 Статус", callback_data="menu_status")
                ],
                [
                    InlineKeyboardButton("🏠 Главная", callback_data="menu_start"),
                    InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text(help_text, reply_markup=reply_markup)
            
        except Exception as e:
            logger.error(f"Ошибка в handle_help: {e}")
    
    async def handle_status(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка команды /status"""
        try:
            tracked_data = self._load_tracked_issues()
            dialog_stats = self.dialog_manager.get_dialog_stats()
            
            user_id = update.effective_user.id
            user_issues_count = sum(1 for issue in tracked_data.values() 
                                  if issue.get('chat_id') == user_id)
            
            active_dialog = self.dialog_manager.get_active_dialog(user_id)
            
            # Определяем режим работы
            bot_mode = "Webhook" if self.use_webhook else "Polling"
            
            status_text = f"""📊 *Статус системы поддержки*

🤖 Telegram бот: *Активен*
📋 YouTrack: *Доступен*
💬 Режим работы: *{bot_mode}*

📈 *Общая статистика:*
• Отслеживаемых задач: {len(tracked_data)}
• Активных диалогов: {dialog_stats['active_dialogs']}
• Ваших активных задач: {user_issues_count}
"""
            
            if active_dialog:
                status_text += f"""
💭 *Ваш активный диалог:*
• Задача: {active_dialog['active_issue']}
• Сообщений в диалоге: {active_dialog.get('message_count', 0)}
• Последняя активность: {active_dialog['last_activity'][:16]}
"""
            
            status_text += """
📎 Поддержка файлов: *Включена* (до 50 МБ)
💬 Поддержка reply: *Включена*

💡 *Для создания заявки:* отправьте сообщение или файл
💬 *Для комментария:* ответьте на сообщение бота"""
            
            # Добавляем кнопки
            keyboard = [
                [
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                    InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text(status_text, reply_markup=reply_markup)
            
        except Exception as e:
            logger.error(f"Ошибка в handle_status: {e}")
    
    async def handle_stats(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Показывает статистику системы (только для админа)"""
        try:
            user_id = update.effective_user.id
            admin_id = self.config['telegram'].get('admin_id')
            
            if admin_id and user_id != admin_id:
                await update.message.reply_text("❌ Эта команда доступна только администратору")
                return
            
            tracked_data = self._load_tracked_issues()
            dialog_stats = self.dialog_manager.get_dialog_stats()
            
            stats_text = f"""📊 *Статистика системы*

📋 *Задачи:*
• Всего задач: {len(tracked_data)}
• За последние 7 дней: {self._count_recent_issues(tracked_data, days=7)}

💬 *Диалоги:*
• Активных диалогов: {dialog_stats['active_dialogs']}
• Чат-сессий всего: {len(dialog_stats['chats_with_dialogs'])}

👤 *Пользователи (топ 10 по задачам):*
{self._get_top_users(tracked_data, limit=10)}

🔄 *Система:*
• Размер данных: {self._get_data_size()}
• Лог-файлы: {self._get_log_size()}"""
            
            await update.message.reply_text(stats_text)
            
        except Exception as e:
            logger.error(f"Ошибка в handle_stats: {e}")
    
    async def handle_message(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка текстовых сообщений с поддержкой reply"""
        user = update.effective_user
        message = update.message
        message_text = message.text
        
        logger.info(f"💬 Сообщение от {user.id}: {message_text[:100]}...")
        
        try:
            await message.reply_chat_action(action="typing")
            
            # Проверяем, является ли это команда через кнопку меню
            if message_text.startswith('/'):
                # Отправляем обработку в существующие обработчики
                return
            
            # 1. Проверяем, является ли это reply к сообщению
            if message.reply_to_message:
                logger.info(f"📨 Это reply к сообщению {message.reply_to_message.message_id}")
                
                # Пробуем найти задачу по reply
                issue_id = self.dialog_manager.get_issue_from_reply(
                    user.id, 
                    message.reply_to_message.message_id
                )
                
                if issue_id:
                    # Добавляем комментарий к существующей задаче
                    await self._add_comment_to_issue(
                        chat_id=user.id,
                        issue_id=issue_id,
                        comment=message_text,
                        author=user.first_name or user.username or "Пользователь"
                    )
                    
                    # Начинаем/обновляем диалог
                    issues_data = self._load_tracked_issues()
                    if issue_id in issues_data:
                        active_dialog = self.dialog_manager.get_active_dialog(user.id)
                        if not active_dialog or active_dialog['active_issue'] != issue_id:
                            self.dialog_manager.start_new_dialog(
                                user.id, 
                                issue_id, 
                                issues_data[issue_id]
                            )
                        else:
                            self.dialog_manager.update_dialog_activity(user.id)
                    
                    return
            
            # 2. Пытаемся определить, к какой задаче относится сообщение
            issue_id = self.dialog_manager.find_issue_for_message(user.id, message_text)
            
            if issue_id:
                # Нашли существующую задачу - добавляем комментарий
                await self._add_comment_to_issue(
                    chat_id=user.id,
                    issue_id=issue_id,
                    comment=message_text,
                    author=user.first_name or user.username or "Пользователь"
                )
                
                # Начинаем/обновляем диалог
                issues_data = self._load_tracked_issues()
                if issue_id in issues_data:
                    active_dialog = self.dialog_manager.get_active_dialog(user.id)
                    if not active_dialog or active_dialog['active_issue'] != issue_id:
                        self.dialog_manager.start_new_dialog(
                            user.id, 
                            issue_id, 
                            issues_data[issue_id]
                        )
                    else:
                        self.dialog_manager.update_dialog_activity(user.id)
                
            elif issue_id is None:
                # Несколько задач - просим уточнить
                user_issues = self.dialog_manager.get_user_issues(user.id)
                
                if user_issues:
                    issues_list = "\n".join([
                        f"• {issue['id']} - {issue['summary'][:50]}..."
                        for issue in user_issues[:5]
                    ])
                    
                    # Создаем кнопки для выбора задач
                    keyboard = []
                    for issue in user_issues[:3]:
                        keyboard.append([
                            InlineKeyboardButton(
                                f"📝 {issue['id'][:10]} - {issue['summary'][:30]}...",
                                callback_data=f"select_issue_{issue['id']}"
                            )
                        ])
                    
                    keyboard.append([
                        InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue"),
                        InlineKeyboardButton("📋 Все задачи", callback_data="menu_myissues")
                    ])
                    
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    response = f"""❓ *Не понятно, к какой задаче относится сообщение*

📋 *Ваши задачи:*
{issues_list}

💡 *Выберите задачу одним из способов:*
1. Ответьте (reply) на сообщение нужной задачи
2. Используйте `/continue MST-123`
3. Укажите номер задачи в сообщении
4. Или отправьте новое сообщение для создания задачи"""
                    
                    await message.reply_text(response, reply_markup=reply_markup)
                    return
                else:
                    # Нет задач - создаем новую
                    await self._create_new_issue(
                        user=user,
                        message_text=message_text,
                        context=context
                    )
            else:
                # issue_id is None и нет задач - создаем новую
                await self._create_new_issue(
                    user=user,
                    message_text=message_text,
                    context=context
                )
                
        except Exception as e:
            logger.error(f"Ошибка обработки сообщения: {e}", exc_info=True)
            await message.reply_text("❌ Ошибка обработки сообщения. Попробуйте позже.")
    
    async def _create_new_issue(self, user, message_text: str, context):
        """Создает новую задачу"""
        ticket_result = await self.youtrack.create_ticket_from_telegram(
            user_id=str(user.id),
            user_name=user.first_name or user.username or "Пользователь",
            message=message_text
        )
        
        if ticket_result['success']:
            response_text = f"""✅ *Заявка создана!*

📋 Номер: `{ticket_result['ticket_id']}`
🔗 Ссылка: {ticket_result['ticket_url']}

💡 *Теперь вы можете:*
• Ответить (reply) на это сообщение, чтобы добавить комментарии
• Упомянуть номер задачи (`{ticket_result['ticket_id']}`) в следующих сообщениях
• Использовать `/continue {ticket_result['ticket_id']}` для продолжения"""
            
            # Добавляем кнопки
            keyboard = [
                [
                    InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{ticket_result['ticket_id']}"),
                    InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{ticket_result['ticket_id']}")
                ],
                [
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                    InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            sent_message = await context.bot.send_message(
                chat_id=user.id,
                text=response_text,
                reply_markup=reply_markup
            )
            
            # Сохраняем связь
            await self._save_issue_chat_link(
                issue_id=ticket_result['ticket_id'],
                chat_id=user.id,
                youtrack_issue_id=ticket_result.get('raw_response', {}).get('id'),
                summary=ticket_result.get('summary', '')
            )
            
            # Создаем связь между сообщением и задачей
            self.dialog_manager.create_issue_reference(
                user.id, 
                ticket_result['ticket_id'], 
                sent_message.message_id
            )
            
            # Начинаем новый диалог
            issues_data = self._load_tracked_issues()
            if ticket_result['ticket_id'] in issues_data:
                self.dialog_manager.start_new_dialog(
                    user.id, 
                    ticket_result['ticket_id'], 
                    issues_data[ticket_result['ticket_id']]
                )
            
            # Уведомление админу
            admin_id = self.config['telegram'].get('admin_id')
            if admin_id:
                admin_msg = f"""📥 *Новая заявка*

👤 Пользователь: {user.first_name or ''} (@{user.username or 'нет'})
🔢 Заявка: {ticket_result['ticket_id']}
💬 Сообщение: {message_text[:200]}..."""
                
                await context.bot.send_message(
                    chat_id=admin_id,
                    text=admin_msg
                )
        else:
            await context.bot.send_message(
                chat_id=user.id,
                text=f"❌ *Не удалось создать заявку:* {ticket_result.get('error', 'Неизвестная ошибка')}"
            )
    
    async def _add_comment_to_issue(self, chat_id: int, issue_id: str, comment: str, author: str):
        """Добавляет комментарий к существующей задаче"""
        try:
            # Проверяем, что задача существует и принадлежит пользователю
            issues_data = self._load_tracked_issues()
            if issue_id not in issues_data or issues_data[issue_id].get('chat_id') != chat_id:
                await self.application.bot.send_message(
                    chat_id=chat_id,
                    text=f"❌ Задача {issue_id} не найдена или не принадлежит вам"
                )
                return False
            
            # Добавляем комментарий через YouTrack API
            success = await self.youtrack.add_comment_to_ticket(issue_id, comment, author)
            
            if success:
                # Добавляем кнопки
                keyboard = [
                    [
                        InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{issue_id}"),
                        InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{issue_id}")
                    ],
                    [
                        InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                        InlineKeyboardButton("❌ Закрыть", callback_data=f"close_{issue_id}")
                    ]
                ]
                reply_markup = InlineKeyboardMarkup(keyboard)
                
                await self.application.bot.send_message(
                    chat_id=chat_id,
                    text=f"✅ Комментарий добавлен к задаче `{issue_id}`",
                    reply_markup=reply_markup
                )
                
                # Обновляем активность диалога
                self.dialog_manager.update_dialog_activity(chat_id)
                
                return True
            else:
                await self.application.bot.send_message(
                    chat_id=chat_id,
                    text=f"❌ Не удалось добавить комментарий к задаче {issue_id}"
                )
                return False
                
        except Exception as e:
            logger.error(f"Ошибка добавления комментария: {e}")
            await self.application.bot.send_message(
                chat_id=chat_id,
                text=f"❌ Ошибка при добавлении комментария: {str(e)[:100]}"
            )
            return False
    
    async def handle_myissues(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Показывает задачи пользователя с кнопками выбора"""
        user = update.effective_user
        issues = self.dialog_manager.get_user_issues(user.id, limit=15)
        
        if not issues:
            # Добавляем кнопки
            keyboard = [
                [
                    InlineKeyboardButton("🆘 Создать задачу", callback_data="menu_newissue"),
                    InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text("📭 У вас нет активных задач", reply_markup=reply_markup)
            return
        
        active_dialog = self.dialog_manager.get_active_dialog(user.id)
        active_issue = active_dialog['active_issue'] if active_dialog else None
        
        issues_list = "\n".join([
            f"{'➤ ' if issue['id'] == active_issue else '• '}`{issue['id']}` - {issue['summary'][:50]}{'...' if len(issue['summary']) > 50 else ''}"
            for issue in issues
        ])
        
        response_text = f"""📋 *Ваши задачи* ({len(issues)}):

{issues_list}

💡 *Как продолжить работу:*
1. Ответьте (reply) на сообщение нужной задачи
2. Используйте `/continue MST-123`
3. Укажите номер задачи в сообщении
4. Используйте `/close` для создания новой задачи"""
        
        if active_issue:
            response_text += f"\n\n📝 *Сейчас активна:* `{active_issue}`"
        
        # Создаем кнопки для задач
        keyboard = []
        for issue in issues[:5]:  # Ограничим 5 задач для кнопок
            keyboard.append([
                InlineKeyboardButton(
                    f"📝 {issue['id']}",
                    callback_data=f"continue_{issue['id']}"
                )
            ])
        
        keyboard.append([
            InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue"),
            InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
        ])
        
        reply_markup = InlineKeyboardMarkup(keyboard)
        
        await update.message.reply_text(response_text, reply_markup=reply_markup)
    
    async def handle_continue(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Продолжить работу с конкретной задачей"""
        user = update.effective_user
        
        if not context.args:
            await update.message.reply_text("❓ Укажите номер задачи: `/continue MST-8`")
            return
        
        issue_id = context.args[0].upper()
        
        # Проверяем формат номера
        if not re.match(r'^(MST|TS|DEMO)-\d+$', issue_id):
            await update.message.reply_text("❌ Неверный формат номера задачи. Пример: `MST-8`")
            return
        
        # Проверяем, существует ли задача
        issues_data = self._load_tracked_issues()
        if issue_id not in issues_data:
            await update.message.reply_text(f"❌ Задача `{issue_id}` не найдена")
            return
        
        # Проверяем, принадлежит ли задача пользователю
        if issues_data[issue_id].get('chat_id') != user.id:
            await update.message.reply_text(f"❌ Задача `{issue_id}` не принадлежит вам")
            return
        
        # Активируем диалог
        self.dialog_manager.start_new_dialog(user.id, issue_id, issues_data[issue_id])
        
        # Добавляем кнопки
        keyboard = [
            [
                InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{issue_id}"),
                InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{issue_id}")
            ],
            [
                InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                InlineKeyboardButton("❌ Закрыть", callback_data=f"close_{issue_id}")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        
        await update.message.reply_text(
            f"✅ *Теперь вы работаете с задачей* `{issue_id}`\n\n"
            f"📝 Все ваши сообщения будут добавляться как комментарии к этой задаче.\n"
            f"🗑️ Чтобы создать новую задачу, используйте `/close`\n\n"
            f"💬 *Последний комментарий:*\n"
            f"{issues_data[issue_id].get('summary', 'Нет информации')[:200]}...",
            reply_markup=reply_markup
        )
    
    async def handle_close(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Закрывает активный диалог"""
        user = update.effective_user
        
        if self.dialog_manager.close_dialog(user.id):
            # Добавляем кнопки
            keyboard = [
                [
                    InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue"),
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues")
                ],
                [
                    InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text(
                "🗑️ *Активный диалог закрыт.*\n\n"
                "📝 Следующее сообщение создаст новую задачу.\n"
                "💬 Или используйте `/continue MST-123` для работы с существующей.",
                reply_markup=reply_markup
            )
        else:
            # Добавляем кнопки
            keyboard = [
                [
                    InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue"),
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            await update.message.reply_text(
                "ℹ️ *У вас нет активного диалога.*\n\n"
                "📝 Следующее сообщение создаст новую задачу.",
                reply_markup=reply_markup
            )
    
    async def handle_document(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка документов с поддержкой диалогов"""
        await self._handle_file(update, context, "документ")
    
    async def handle_photo(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка фотографий"""
        await self._handle_file(update, context, "фото")
    
    async def handle_video(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка видео"""
        await self._handle_file(update, context, "видео")
    
    async def handle_audio(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка аудио"""
        await self._handle_file(update, context, "аудио")
    
    async def _handle_file(self, update: Update, context: ContextTypes.DEFAULT_TYPE, file_type: str):
        """Общая обработка файлов"""
        user = update.effective_user
        message = update.message
        
        try:
            # Определяем активный диалог
            active_dialog = self.dialog_manager.get_active_dialog(user.id)
            issue_id = None
            
            # Проверяем, является ли это reply к сообщению
            if message.reply_to_message:
                issue_id = self.dialog_manager.get_issue_from_reply(
                    user.id, 
                    message.reply_to_message.message_id
                )
            
            # Если нет reply, проверяем активный диалог
            if not issue_id and active_dialog:
                issue_id = active_dialog['active_issue']
            
            file_info = None
            file_name = ""
            
            if file_type == "документ" and message.document:
                file_info = message.document
                file_name = file_info.file_name or f"document_{file_info.file_id}"
            elif file_type == "фото" and message.photo:
                file_info = message.photo[-1]
                file_name = f"photo_{file_info.file_id}.jpg"
            elif file_type == "видео" and message.video:
                file_info = message.video
                file_name = file_info.file_name or f"video_{file_info.file_id}.mp4"
            elif file_type == "аудио":
                if message.audio:
                    file_info = message.audio
                    file_name = file_info.file_name or f"audio_{file_info.file_id}.mp3"
                elif message.voice:
                    file_info = message.voice
                    file_name = f"voice_{file_info.file_id}.ogg"
                    file_type = "голосовое сообщение"
            
            if not file_info:
                await message.reply_text("❌ Не удалось обработать файл")
                return
            
            # Проверяем размер файла
            if hasattr(file_info, 'file_size') and file_info.file_size:
                if file_info.file_size > self.max_file_size:
                    size_mb = self.max_file_size / (1024 * 1024)
                    await message.reply_text(f"❌ Файл слишком большой. Максимальный размер: {size_mb:.0f} МБ")
                    return
            
            logger.info(f"Получение файла {file_name} от {user.id}")
            await message.reply_chat_action(action="upload_document")
            
            file = await file_info.get_file()
            
            # Сохраняем файл локально
            local_path = self.uploads_dir / file_name
            
            # Создаем уникальное имя файла
            counter = 1
            while local_path.exists():
                name_parts = file_name.rsplit('.', 1)
                if len(name_parts) == 2:
                    new_name = f"{name_parts[0]}_{counter}.{name_parts[1]}"
                else:
                    new_name = f"{file_name}_{counter}"
                local_path = self.uploads_dir / new_name
                counter += 1
            
            await file.download_to_drive(local_path)
            
            # Получаем размер файла
            file_size = local_path.stat().st_size
            file_size_mb = file_size / (1024 * 1024)
            
            logger.info(f"Получен {file_type} от {user.id}: {local_path.name} ({file_size_mb:.2f} МБ)")
            
            await message.reply_chat_action(action="typing")
            
            # Исправляем получение caption - делаем его более читаемым
            if message.caption:
                caption = message.caption
            else:
                # Создаем понятное описание
                if file_type == "фото":
                    caption = f"Отправлено фото"
                elif file_type == "документ":
                    caption = f"Отправлен документ: {local_path.name}"
                elif file_type == "видео":
                    caption = f"Отправлено видео"
                elif file_type == "аудио":
                    caption = f"Отправлено аудио"
                elif file_type == "голосовое сообщение":
                    caption = f"Отправлено голосовое сообщение"
                else:
                    caption = f"Отправлен файл: {local_path.name}"
            
            # Если есть активная задача, добавляем файл к ней
            if issue_id:
                # Прикрепляем файл к существующей задаче
                attach_result = await self.youtrack.attach_file_to_ticket(
                    issue_id=issue_id,
                    file_path=local_path,
                    file_name=local_path.name,
                    comment=caption
                )
                
                if attach_result['success']:
                    size_info = f"{file_size_mb:.2f} МБ" if file_size_mb >= 1 else f"{file_size / 1024:.0f} КБ"
                    
                    # Форматируем сообщение для лучшего отображения
                    response_text = f"""✅ *Файл добавлен к задаче* `{issue_id}`

📎 *Файл:* `{local_path.name}`
📊 *Тип:* {file_type}
📦 *Размер:* {size_info}"""
                    
                    if caption and caption != f"Отправлен {file_type}: {local_path.name}":
                        response_text += f"\n💬 *Описание:* {caption}"
                    
                    # Добавляем кнопки
                    keyboard = [
                        [
                            InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{issue_id}"),
                            InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{issue_id}")
                        ],
                        [
                            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                            InlineKeyboardButton("❌ Закрыть", callback_data=f"close_{issue_id}")
                        ]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    # Обновляем активность диалога
                    self.dialog_manager.update_dialog_activity(user.id)
                    
                else:
                    response_text = f"❌ Не удалось прикрепить файл к задаче {issue_id}"
                    reply_markup = None
            else:
                # Создаем новую задачу с файлом
                ticket_result = await self.youtrack.create_ticket_from_telegram(
                    user_id=str(user.id),
                    user_name=user.first_name or user.username or "Пользователь",
                    message=caption,
                    file_path=local_path,
                    file_name=local_path.name,
                    file_type=file_type
                )
                
                if ticket_result['success']:
                    size_info = f"{file_size_mb:.2f} МБ" if file_size_mb >= 1 else f"{file_size / 1024:.0f} КБ"
                    
                    response_text = f"""✅ *Заявка с файлом создана!*

📎 *Файл:* `{local_path.name}`
📊 *Тип:* {file_type}
📦 *Размер:* {size_info}

📋 *Номер:* `{ticket_result['ticket_id']}`
🔗 *Ссылка:* {ticket_result['ticket_url']}"""
                    
                    if caption:
                        response_text += f"\n💬 *Описание:* {caption}"
                    
                    response_text += f"""

💡 *Теперь вы можете ответить (reply) на это сообщение*"""
                    
                    # Добавляем кнопки
                    keyboard = [
                        [
                            InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{ticket_result['ticket_id']}"),
                            InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{ticket_result['ticket_id']}")
                        ],
                        [
                            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
                            InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
                        ]
                    ]
                    reply_markup = InlineKeyboardMarkup(keyboard)
                    
                    sent_message = await message.reply_text(response_text, reply_markup=reply_markup)
                    
                    # Сохраняем связь
                    await self._save_issue_chat_link(
                        issue_id=ticket_result['ticket_id'],
                        chat_id=user.id,
                        youtrack_issue_id=ticket_result.get('raw_response', {}).get('id'),
                        summary=ticket_result.get('summary', '')
                    )
                    
                    # Создаем связь между сообщением и задачей
                    self.dialog_manager.create_issue_reference(
                        user.id, 
                        ticket_result['ticket_id'], 
                        sent_message.message_id
                    )
                    
                    # Начинаем новый диалог
                    issues_data = self._load_tracked_issues()
                    if ticket_result['ticket_id'] in issues_data:
                        self.dialog_manager.start_new_dialog(
                            user.id, 
                            ticket_result['ticket_id'], 
                            issues_data[ticket_result['ticket_id']]
                        )
                    
                    # Уведомление админу
                    admin_id = self.config['telegram'].get('admin_id')
                    if admin_id:
                        admin_msg = f"""📎 *Новая заявка с файлом*

👤 *Пользователь:* {user.first_name or ''} (@{user.username or 'нет'})
📎 *Файл:* {local_path.name} ({file_type})
🔢 *Заявка:* {ticket_result['ticket_id']}"""
                        
                        if caption:
                            admin_msg += f"\n💬 *Описание:* {caption[:200]}..."
                        
                        await context.bot.send_message(
                            chat_id=admin_id,
                            text=admin_msg
                        )
                else:
                    response_text = f"❌ *Не удалось создать заявку:* {ticket_result.get('error', 'Неизвестная ошибка')}"
                    reply_markup = None
            
            await message.reply_text(response_text, reply_markup=reply_markup)
            
            # Очистка временного файла
            if self.cleanup_after_upload and local_path.exists():
                try:
                    local_path.unlink()
                    logger.info(f"Временный файл удален: {local_path.name}")
                except Exception as e:
                    logger.warning(f"Не удалось удалить временный файл: {e}")
                
        except NetworkError as e:
            logger.error(f"Сетевая ошибка при обработке файла: {e}")
            await message.reply_text("❌ Сетевая ошибка. Файл слишком большой или проблемы с сетью.")
        except TimedOut as e:
            logger.error(f"Таймаут при обработке файла: {e}")
            await message.reply_text("⏱️ Таймаут. Обработка файла заняла слишком много времени.")
        except Exception as e:
            logger.error(f"Ошибка обработки файла: {e}", exc_info=True)
            await message.reply_text(f"❌ Ошибка при обработке {file_type}. Попробуйте отправить файл еще раз.")
    
    async def error_handler(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """Обработка ошибок Telegram API"""
        try:
            logger.error(f"Ошибка Telegram: {context.error}", exc_info=True)
        except Exception as e:
            logger.error(f"Ошибка в обработчике ошибок: {e}")
    
    def _load_tracked_issues(self):
        """Загружает данные отслеживаемых задач"""
        try:
            issues_file = self.data_dir / 'tracked_issues.json'
            if issues_file.exists():
                with open(issues_file, 'r', encoding='utf-8') as f:
                    return json.load(f)
            return {}
        except:
            return {}
    
    async def _save_issue_chat_link(self, issue_id: str, chat_id: int, 
                                   youtrack_issue_id: str = None, summary: str = ""):
        """Сохраняет связь между задачей и чатом"""
        try:
            issues_data = self._load_tracked_issues()
            
            from datetime import datetime
            created_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            
            issues_data[issue_id] = {
                'chat_id': chat_id,
                'youtrack_issue_id': youtrack_issue_id or issue_id,
                'created_at': created_at,
                'summary': summary[:200] if summary else "",
                'last_updated': created_at
            }
            
            issues_file = self.data_dir / 'tracked_issues.json'
            with open(issues_file, 'w', encoding='utf-8') as f:
                json.dump(issues_data, f, indent=2, ensure_ascii=False)
                
        except Exception as e:
            logger.error(f"Ошибка сохранения связи: {e}")
    
    def _count_recent_issues(self, tracked_data, days=7):
        """Считает задачи за последние N дней"""
        try:
            from datetime import datetime, timedelta
            cutoff_date = datetime.now() - timedelta(days=days)
            count = 0
            
            for issue_id, issue_data in tracked_data.items():
                created_at = issue_data.get('created_at')
                if created_at:
                    issue_date = datetime.strptime(created_at[:10], "%Y-%m-%d")
                    if issue_date >= cutoff_date:
                        count += 1
            
            return count
        except:
            return "Н/Д"
    
    def _get_top_users(self, tracked_data, limit=10):
        """Получает топ пользователей по количеству задач"""
        try:
            from collections import Counter
            user_ids = [issue_data.get('chat_id') for issue_data in tracked_data.values()]
            user_counts = Counter(user_ids)
            
            result = []
            for user_id, count in user_counts.most_common(limit):
                result.append(f"• ID {user_id}: {count} задач")
            
            return "\n".join(result) if result else "Нет данных"
        except:
            return "Нет данных"
    
    def _get_data_size(self):
        """Получает размер данных"""
        try:
            import os
            
            def get_dir_size(path):
                total = 0
                for entry in os.scandir(path):
                    if entry.is_file():
                        total += entry.stat().st_size
                    elif entry.is_dir():
                        total += get_dir_size(entry.path)
                return total
            
            data_size = get_dir_size(self.data_dir)
            
            if data_size < 1024:
                return f"{data_size} Б"
            elif data_size < 1024 * 1024:
                return f"{data_size / 1024:.1f} КБ"
            else:
                return f"{data_size / (1024 * 1024):.1f} МБ"
        except:
            return "Н/Д"
    
    def _get_log_size(self):
        """Получает размер лог-файлов"""
        try:
            import os
            
            if os.path.exists(self.data_dir / 'tracked_issues.json'):
                size = os.path.getsize(self.data_dir / 'tracked_issues.json')
                if size < 1024:
                    return f"{size} Б"
                elif size < 1024 * 1024:
                    return f"{size / 1024:.1f} КБ"
                else:
                    return f"{size / (1024 * 1024):.1f} МБ"
            return "Нет файлов"
        except:
            return "Н/Д"
EOF

# Создаем callback_handler.py
print_status "Создание callback_handler.py..."
sudo -u "$USER_NAME" cat > "$APP_DIR/app/callback_handler.py" << 'EOF'
#!/usr/bin/env python3
"""
Обработчик callback-кнопок для Telegram бота
"""

import logging
from telegram import Update, InlineKeyboardMarkup, InlineKeyboardButton
from telegram.ext import ContextTypes, CallbackQueryHandler

logger = logging.getLogger(__name__)

async def handle_callback_query(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Обработка callback-запросов от inline-кнопок"""
    query = update.callback_query
    await query.answer()  # Ответим на callback, чтобы убрать часики
    
    user_id = update.effective_user.id
    callback_data = query.data
    
    logger.info(f"Callback от {user_id}: {callback_data}")
    
    try:
        # Обработка меню
        if callback_data == "menu_start":
            await handle_menu_start(query, context)
        elif callback_data == "menu_help":
            await handle_menu_help(query, context)
        elif callback_data == "menu_status":
            await handle_menu_status(query, context)
        elif callback_data == "menu_myissues":
            await handle_menu_myissues(query, context)
        elif callback_data == "menu_newissue":
            await handle_menu_newissue(query, context)
        
        # Обработка выбора задачи
        elif callback_data.startswith("select_issue_"):
            issue_id = callback_data.replace("select_issue_", "")
            await handle_select_issue(query, context, issue_id)
        
        # Обработка действий с задачами
        elif callback_data.startswith("continue_"):
            issue_id = callback_data.replace("continue_", "")
            await handle_continue_issue(query, context, issue_id)
        elif callback_data.startswith("reply_"):
            issue_id = callback_data.replace("reply_", "")
            await handle_reply_issue(query, context, issue_id)
        elif callback_data.startswith("close_"):
            issue_id = callback_data.replace("close_", "")
            await handle_close_issue(query, context, issue_id)
        
    except Exception as e:
        logger.error(f"Ошибка обработки callback: {e}")
        await query.edit_message_text("❌ Произошла ошибка. Попробуйте еще раз.")

async def handle_menu_start(query, context):
    """Обработка кнопки 'Главная'"""
    welcome_text = """👋 *Главное меню*

Выберите действие из меню или используйте команды:

📋 /myissues - Мои задачи
📊 /status - Статус системы
❓ /help - Помощь
🆘 Просто отправьте сообщение - создастся новая задача"""
    
    keyboard = [
        [
            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
            InlineKeyboardButton("📊 Статус", callback_data="menu_status")
        ],
        [
            InlineKeyboardButton("❓ Помощь", callback_data="menu_help"),
            InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(welcome_text, reply_markup=reply_markup)

async def handle_menu_help(query, context):
    """Обработка кнопки 'Помощь'"""
    help_text = """📚 *Помощь*

*Доступные команды:*
• /start - Главное меню
• /help - Эта справка
• /status - Статус системы
• /myissues - Мои задачи
• /close - Закрыть диалог
• /continue MST-123 - Продолжить работу

*Быстрые действия:*
• Ответьте (reply) на сообщение бота - добавится комментарий
• Укажите номер задачи в сообщении
• Прикрепляйте файлы к задачам

*Поддерживаемые файлы:* документы, фото, видео, аудио (до 50 МБ)"""
    
    keyboard = [
        [
            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
            InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(help_text, reply_markup=reply_markup)

async def handle_menu_status(query, context):
    """Обработка кнопки 'Статус'"""
    # Нужен доступ к боту через context.bot_data
    bot = context.bot_data.get('bot_instance')
    if not bot:
        await query.edit_message_text("❌ Сервис временно недоступен")
        return
    
    tracked_data = bot._load_tracked_issues()
    dialog_stats = bot.dialog_manager.get_dialog_stats()
    
    user_issues_count = sum(1 for issue in tracked_data.values() 
                          if issue.get('chat_id') == query.from_user.id)
    
    active_dialog = bot.dialog_manager.get_active_dialog(query.from_user.id)
    
    status_text = f"""📊 *Статус системы*

🤖 Telegram бот: *Активен*
📋 YouTrack: *Доступен*

📈 *Ваша статистика:*
• Ваших задач: {user_issues_count}
• Активных диалогов: {dialog_stats['active_dialogs']}"""
    
    if active_dialog:
        status_text += f"""
📝 *Активная задача:* {active_dialog['active_issue']}
"""
    
    status_text += """
📎 Поддержка файлов: *Включена* (до 50 МБ)
💬 Поддержка reply: *Включена*"""
    
    keyboard = [
        [
            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
            InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(status_text, reply_markup=reply_markup)

async def handle_menu_myissues(query, context):
    """Обработка кнопки 'Мои задачи'"""
    bot = context.bot_data.get('bot_instance')
    if not bot:
        await query.edit_message_text("❌ Сервис временно недоступен")
        return
    
    user = query.from_user
    issues = bot.dialog_manager.get_user_issues(user.id, limit=10)
    
    if not issues:
        keyboard = [
            [
                InlineKeyboardButton("🆘 Создать задачу", callback_data="menu_newissue"),
                InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        
        await query.edit_message_text("📭 У вас нет активных задач", reply_markup=reply_markup)
        return
    
    issues_list = "\n".join([
        f"• `{issue['id']}` - {issue['summary'][:50]}{'...' if len(issue['summary']) > 50 else ''}"
        for issue in issues
    ])
    
    response_text = f"""📋 *Ваши задачи* ({len(issues)}):

{issues_list}

💡 *Выберите задачу для продолжения работы:*"""
    
    # Создаем кнопки для задач
    keyboard = []
    for issue in issues[:5]:  # Ограничим 5 задач для кнопок
        keyboard.append([
            InlineKeyboardButton(
                f"📝 {issue['id']}",
                callback_data=f"continue_{issue['id']}"
            )
        ])
    
    keyboard.append([
        InlineKeyboardButton("🆘 Новая задача", callback_data="menu_newissue"),
        InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
    ])
    
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(response_text, reply_markup=reply_markup)

async def handle_menu_newissue(query, context):
    """Обработка кнопки 'Новая задача'"""
    text = """🆘 *Создание новой задачи*

Просто отправьте сообщение с описанием проблемы.

📎 *Можно прикрепить:*
• Текст сообщения
• Документы
• Фотографии
• Видео
• Аудио файлы

📦 *Максимальный размер:* 50 МБ

💡 Сообщение появится как новая задача в системе поддержки."""
    
    keyboard = [
        [
            InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues"),
            InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(text, reply_markup=reply_markup)

async def handle_select_issue(query, context, issue_id):
    """Обработка выбора задачи"""
    bot = context.bot_data.get('bot_instance')
    if not bot:
        await query.edit_message_text("❌ Сервис временно недоступен")
        return
    
    # Активируем диалог
    issues_data = bot._load_tracked_issues()
    if issue_id in issues_data:
        bot.dialog_manager.start_new_dialog(query.from_user.id, issue_id, issues_data[issue_id])
        
        text = f"""✅ *Теперь вы работаете с задачей* `{issue_id}`

Все ваши сообщения будут добавляться как комментарии к этой задаче.

🗑️ Чтобы создать новую задачу, используйте /close"""
        
        keyboard = [
            [
                InlineKeyboardButton("💬 Ответить сейчас", callback_data=f"reply_{issue_id}"),
                InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues")
            ],
            [
                InlineKeyboardButton("🏠 Главная", callback_data="menu_start")
            ]
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)
        
        await query.edit_message_text(text, reply_markup=reply_markup)
    else:
        await query.edit_message_text(f"❌ Задача `{issue_id}` не найдена")

async def handle_continue_issue(query, context, issue_id):
    """Обработка кнопки 'Продолжить' для задачи"""
    await query.edit_message_text(
        f"✅ *Продолжение работы с задачей* `{issue_id}`\n\n"
        f"Теперь отправьте сообщение, и оно добавится как комментарий к этой задаче.\n\n"
        f"Или используйте команду: `/continue {issue_id}`"
    )

async def handle_reply_issue(query, context, issue_id):
    """Обработка кнопки 'Ответить' для задачи"""
    await query.edit_message_text(
        f"💬 *Ответ на задачу* `{issue_id}`\n\n"
        f"Отправьте сообщение, и оно добавится как комментарий.\n\n"
        f"*Совет:* Вы также можете ответить (reply) на любое сообщение бота "
        f"о задаче `{issue_id}`"
    )

async def handle_close_issue(query, context, issue_id):
    """Обработка кнопки 'Закрыть' для задачи"""
    bot = context.bot_data.get('bot_instance')
    if not bot:
        await query.edit_message_text("❌ Сервис временно недоступен")
        return
    
    if bot.dialog_manager.close_dialog(query.from_user.id):
        await query.edit_message_text(
            f"🗑️ *Диалог по задаче* `{issue_id}` *закрыт*\n\n"
            f"Следующее сообщение создаст новую задачу.\n"
            f"Чтобы вернуться к этой задаче, используйте `/continue {issue_id}`"
        )
    else:
        await query.edit_message_text(
            f"ℹ️ *У вас нет активного диалога*\n\n"
            f"Следующее сообщение создаст новую задачу."
        )
EOF

# Создаем youtrack.py
sudo -u "$USER_NAME" cat > "$APP_DIR/app/youtrack.py" << 'EOF'
#!/usr/bin/env python3
"""
YouTrack API клиент с поддержкой файлов и комментариев
"""

import aiohttp
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime
import json
import mimetypes
from pathlib import Path

logger = logging.getLogger(__name__)

class YouTrackClient:
    def __init__(self, base_url: str, token: str, project_id: str = "MST"):
        self.base_url = base_url.rstrip('/')
        self.token = token
        self.project_id = project_id
        self.headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        }
        self.projects_map = {
            "MST": "0-1",
            "DEMO": "0-0"
        }
    
    async def test_connection(self) -> bool:
        """Проверка подключения к YouTrack"""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{self.base_url}/users/me",
                    headers=self.headers,
                    timeout=30,
                    ssl=False
                ) as response:
                    
                    if response.status == 200:
                        user_info = await response.json()
                        logger.info(f"✅ Подключение успешно. Пользователь: {user_info.get('name', 'N/A')}")
                        return True
                    else:
                        error_text = await response.text()
                        logger.error(f"❌ Ошибка подключения: {response.status} - {error_text}")
                        return False
        except Exception as e:
            logger.error(f"❌ Исключение при подключении: {e}")
            return False
    
    async def create_ticket_from_telegram(self, user_id: str, user_name: str, message: str, 
                                        file_path: Path = None, file_name: str = None, 
                                        file_type: str = None) -> Dict[str, Any]:
        """Создание тикета из сообщения Telegram"""
        
        project_id = self.projects_map.get(self.project_id)
        if not project_id:
            return {
                'success': False,
                'error': f"Проект '{self.project_id}' не найден в маппинге"
            }
        
        # Формируем заголовок
        if file_name:
            summary = f"Telegram: {user_name} - {file_name}"
            if len(message) > 50:
                summary += f" - {message[:50]}..."
        else:
            summary = f"Telegram: {user_name} - {message[:50]}{'...' if len(message) > 50 else ''}"
        
        # Формируем описание
        description = f"""📱 *Запрос из Telegram*

*👤 Информация о пользователе:*
• ID: {user_id}
• Имя: {user_name}

"""
        
        if file_name:
            description += f"""*📎 Прикрепленный файл:*
• Имя: {file_name}
• Тип: {file_type or 'файл'}

"""
        
        description += f"""*💬 Сообщение:*
{message}

*📅 Дата:* {datetime.now().strftime('%d.%m.%Y %H:%M:%S')}
*🔗 Источник:* Telegram Bot
"""
        
        ticket_data = {
            "project": {"id": project_id},
            "summary": summary,
            "description": description
        }
        
        logger.info(f"Создание задачи в проекте {self.project_id} с {'файлом' if file_path else 'текстом'}")
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.base_url}/issues",
                    headers=self.headers,
                    json=ticket_data,
                    timeout=60,
                    ssl=False
                ) as response:
                    
                    response_text = await response.text()
                    
                    if response.status == 200:
                        result = await response.json()
                        issue_id = result.get('id', 'Unknown')
                        
                        # Получаем читаемый ID
                        try:
                            async with session.get(
                                f"{self.base_url}/issues/{issue_id}?fields=idReadable,summary",
                                headers=self.headers,
                                timeout=30,
                                ssl=False
                            ) as issue_response:
                                if issue_response.status == 200:
                                    issue_info = await issue_response.json()
                                    ticket_id = issue_info.get('idReadable', issue_id)
                                    summary_text = issue_info.get('summary', '')
                                else:
                                    ticket_id = issue_id
                                    summary_text = ''
                        except:
                            ticket_id = issue_id
                            summary_text = ''
                        
                        logger.info(f"✅ Задача создана: {ticket_id}")
                        
                        # Прикрепляем файл если есть
                        file_attached = False
                        if file_path and file_path.exists():
                            attach_result = await self._attach_file_to_issue(
                                session, issue_id, file_path, file_name
                            )
                            file_attached = attach_result['success']
                        
                        return {
                            'success': True,
                            'ticket_id': ticket_id,
                            'ticket_url': f"https://yt.celteh.net/issue/{ticket_id}",
                            'summary': summary_text,
                            'raw_response': result,
                            'internal_id': issue_id,
                            'file_attached': file_attached
                        }
                    else:
                        logger.error(f"❌ Ошибка создания задачи: {response.status} - {response_text}")
                        return {
                            'success': False,
                            'error': f"HTTP {response.status}: {response_text[:200]}",
                            'status_code': response.status,
                            'response_text': response_text
                        }
                        
        except Exception as e:
            logger.error(f"❌ Исключение при создании задачи: {e}")
            return {
                'success': False,
                'error': str(e)
            }
    
    async def add_comment_to_ticket(self, issue_id: str, comment: str, author: str) -> bool:
        """Добавляет комментарий к задаче"""
        try:
            # Сначала получаем internal ID задачи
            internal_id = await self._get_issue_internal_id(issue_id)
            if not internal_id:
                logger.error(f"Не удалось найти internal ID для задачи {issue_id}")
                return False
            
            # Формируем текст комментария
            comment_text = f"""💬 *Комментарий из Telegram*

👤 *Автор:* {author}
📅 *Дата:* {datetime.now().strftime('%d.%m.%Y %H:%M:%S')}

{comment}"""
            
            comment_data = {
                "text": comment_text
            }
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.base_url}/issues/{internal_id}/comments",
                    headers=self.headers,
                    json=comment_data,
                    timeout=30,
                    ssl=False
                ) as response:
                    
                    if response.status == 200:
                        logger.info(f"✅ Комментарий добавлен к задаче {issue_id}")
                        return True
                    else:
                        error_text = await response.text()
                        logger.error(f"❌ Ошибка добавления комментария: {response.status} - {error_text}")
                        return False
                        
        except Exception as e:
            logger.error(f"❌ Исключение при добавлении комментария: {e}")
            return False
    
    async def attach_file_to_ticket(self, issue_id: str, file_path: Path, file_name: str, comment: str = None) -> Dict[str, Any]:
        """Прикрепляет файл к задаче"""
        try:
            internal_id = await self._get_issue_internal_id(issue_id)
            if not internal_id:
                return {
                    'success': False,
                    'error': f"Не удалось найти internal ID для задачи {issue_id}"
                }
            
            # Сначала добавляем комментарий если есть
            if comment:
                await self.add_comment_to_ticket(issue_id, f"Прикреплен файл: {file_name}\n\n{comment}", "Telegram Bot")
            
            # Затем прикрепляем файл
            with open(file_path, 'rb') as f:
                file_content = f.read()
            
            mime_type, _ = mimetypes.guess_type(file_name)
            if not mime_type:
                mime_type = 'application/octet-stream'
            
            form_data = aiohttp.FormData()
            form_data.add_field('file', file_content, filename=file_name, content_type=mime_type)
            
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.base_url}/issues/{internal_id}/attachments",
                    headers={
                        'Authorization': self.headers['Authorization'],
                        'Accept': 'application/json'
                    },
                    data=form_data,
                    timeout=120,
                    ssl=False
                ) as response:
                    
                    response_text = await response.text()
                    
                    if response.status in [200, 201]:
                        logger.info(f"✅ Файл {file_name} прикреплен к задаче {issue_id}")
                        return {
                            'success': True,
                            'filename': file_name,
                            'size': len(file_content)
                        }
                    else:
                        logger.error(f"❌ Ошибка прикрепления файла: {response.status} - {response_text[:200]}")
                        return {
                            'success': False,
                            'error': f"HTTP {response.status}: {response_text[:200]}"
                        }
                    
        except Exception as e:
            logger.error(f"❌ Исключение при прикреплении файла: {e}")
            return {
                'success': False,
                'error': str(e)
            }
    
    async def _get_issue_internal_id(self, issue_id: str) -> Optional[str]:
        """Получает internal ID задачи по её номеру"""
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{self.base_url}/issues/{issue_id}?fields=id",
                    headers=self.headers,
                    timeout=30,
                    ssl=False
                ) as response:
                    
                    if response.status == 200:
                        data = await response.json()
                        return data.get('id')
                    return None
                    
        except Exception as e:
            logger.error(f"Ошибка получения internal ID: {e}")
            return None
    
    async def _attach_file_to_issue(self, session, issue_id: str, file_path: Path, file_name: str) -> Dict[str, Any]:
        """Прикрепляет файл к задаче"""
        try:
            with open(file_path, 'rb') as f:
                file_content = f.read()
            
            mime_type, _ = mimetypes.guess_type(file_name)
            if not mime_type:
                mime_type = 'application/octet-stream'
            
            form_data = aiohttp.FormData()
            form_data.add_field('file', file_content, filename=file_name, content_type=mime_type)
            
            async with session.post(
                f"{self.base_url}/issues/{issue_id}/attachments",
                headers={
                    'Authorization': self.headers['Authorization'],
                    'Accept': 'application/json'
                },
                data=form_data,
                timeout=120,
                ssl=False
            ) as response:
                
                response_text = await response.text()
                
                if response.status in [200, 201]:
                    logger.info(f"✅ Файл {file_name} прикреплен к задаче {issue_id}")
                    return {
                        'success': True,
                        'filename': file_name,
                        'size': len(file_content)
                    }
                else:
                    logger.error(f"❌ Ошибка прикрепления файла: {response.status} - {response_text[:200]}")
                    return {
                        'success': False,
                        'error': f"HTTP {response.status}: {response_text[:200]}"
                    }
                    
        except Exception as e:
            logger.error(f"❌ Исключение при прикреплении файла: {e}")
            return {
                'success': False,
                'error': str(e)
            }
    
    async def get_comments(self, issue_id: str, fields: str = "id,text,created,author(name)", limit: int = 100) -> List[Dict[str, Any]]:
        """Получает комментарии к задаче"""
        try:
            async with aiohttp.ClientSession() as session:
                url = f"{self.base_url}/issues/{issue_id}/comments"
                if fields:
                    url += f"?fields={fields}"
                if limit:
                    url += f"&$top={limit}" if '?' in url else f"?$top={limit}"
                
                async with session.get(
                    url,
                    headers=self.headers,
                    timeout=30,
                    ssl=False
                ) as response:
                    
                    if response.status == 200:
                        comments_data = await response.json()
                        if isinstance(comments_data, list):
                            return comments_data
                        elif isinstance(comments_data, dict) and 'comments' in comments_data:
                            return comments_data['comments']
                        else:
                            return []
                    else:
                        return []
                        
        except Exception as e:
            logger.error(f"Ошибка получения комментариев: {e}")
            return []
    
    async def get_new_comments(self, issue_id: str, last_comment_id: str = None) -> List[Dict[str, Any]]:
        """Получает новые комментарии"""
        all_comments = await self.get_comments(issue_id)
        
        if not all_comments or not last_comment_id:
            return all_comments
        
        # Ищем последний комментарий
        last_index = -1
        for i, comment in enumerate(all_comments):
            if comment.get('id') == last_comment_id:
                last_index = i
                break
        
        if last_index >= 0:
            return all_comments[last_index + 1:]
        else:
            return all_comments
    
    async def get_comment_author(self, comment: Dict[str, Any]) -> str:
        """Извлекает имя автора"""
        try:
            author = comment.get('author', {})
            if isinstance(author, dict):
                return author.get('name', 'Неизвестный')
            return str(author)
        except:
            return 'Неизвестный'
    
    async def is_comment_from_telegram_bot(self, comment: Dict[str, Any]) -> bool:
        """Проверяет, является ли комментарий от бота"""
        try:
            text = comment.get('text', '')
            bot_indicators = [
                '📱 *Запрос из Telegram*',
                'Telegram Bot',
                '👤 Информация о пользователе:',
                '*🔗 Источник:* Telegram Bot',
                '💬 *Комментарий из Telegram*'
            ]
            return any(indicator in text for indicator in bot_indicators)
        except:
            return False
EOF

# Создаем comment_checker.py
sudo -u "$USER_NAME" cat > "$APP_DIR/app/comment_checker.py" << 'EOF'
#!/usr/bin/env python3
"""
Модуль для проверки новых комментариев в YouTrack и отправки уведомлений в Telegram
"""

import asyncio
import logging
from datetime import datetime
from typing import Dict, Any, List
import json
import re

logger = logging.getLogger(__name__)

class CommentChecker:
    def __init__(self, telegram_bot, youtrack_client, config: dict):
        self.bot = telegram_bot
        self.youtrack = youtrack_client
        self.config = config
        self.check_interval = config['youtrack'].get('poll_interval', 30)  # секунды
        self.running = False
        
        logger.info(f"Инициализирован проверщик комментариев с интервалом {self.check_interval} секунд")
    
    async def start(self):
        """Запуск проверки комментариев"""
        self.running = True
        logger.info("🚀 Запуск системы проверки комментариев...")
        
        try:
            while self.running:
                try:
                    await self.check_all_issues()
                except Exception as e:
                    logger.error(f"Ошибка при проверке комментариев: {e}")
                
                # Ждем указанный интервал
                await asyncio.sleep(self.check_interval)
                
        except KeyboardInterrupt:
            logger.info("Проверка комментариев остановлена")
        except Exception as e:
            logger.error(f"Критическая ошибка в проверщике комментариев: {e}")
            self.running = False
    
    async def check_all_issues(self):
        """Проверяет все отслеживаемые задачи на новые комментарии"""
        try:
            # Получаем отслеживаемые задачи из бота
            tracked_issues = self.bot._load_tracked_issues()
            
            if not tracked_issues:
                # logger.debug("Нет отслеживаемых задач для проверки")
                return
            
            logger.info(f"🔍 Проверяю {len(tracked_issues)} задач на новые комментарии...")
            
            checked_count = 0
            new_comments_count = 0
            
            for issue_id, issue_data in tracked_issues.items():
                try:
                    if not issue_data.get('notifications_enabled', True):
                        continue  # Пропускаем задачи с отключенными уведомлениями
                    
                    checked_count += 1
                    new_comments = await self.check_issue_comments(issue_id, issue_data)
                    
                    if new_comments:
                        new_comments_count += len(new_comments)
                    
                    # Небольшая задержка между проверками разных задач
                    await asyncio.sleep(0.3)
                    
                except Exception as e:
                    logger.error(f"Ошибка проверки задачи {issue_id}: {e}")
            
            if checked_count > 0:
                logger.info(f"✅ Проверено {checked_count} задач, найдено {new_comments_count} новых комментариев")
        
        except Exception as e:
            logger.error(f"Ошибка при проверке всех задач: {e}")
    
    async def check_issue_comments(self, issue_id: str, issue_data: Dict[str, Any]):
        """Проверяет новые комментарии для конкретной задачи"""
        try:
            chat_id = issue_data.get('chat_id')
            last_comment_id = issue_data.get('last_comment_id')
            
            if not chat_id:
                logger.warning(f"У задачи {issue_id} не указан chat_id")
                return []
            
            # Получаем новые комментарии
            new_comments = await self.youtrack.get_new_comments(
                issue_id=issue_id,
                last_comment_id=last_comment_id
            )
            
            if not new_comments:
                return []
            
            logger.info(f"📨 Найдено {len(new_comments)} новых комментариев для задачи {issue_id}")
            
            processed_comments = []
            
            # Обрабатываем каждый новый комментарий
            for comment in new_comments:
                try:
                    processed = await self.process_comment(issue_id, chat_id, comment)
                    
                    if processed:
                        processed_comments.append(comment)
                        
                        # Обновляем ID последнего обработанного комментария
                        comment_id = comment.get('id')
                        if comment_id:
                            self.update_issue_last_comment(issue_id, comment_id)
                            
                except Exception as e:
                    logger.error(f"Ошибка обработки комментария {comment.get('id')}: {e}")
            
            return processed_comments
            
        except Exception as e:
            logger.error(f"Ошибка проверки комментариев для задачи {issue_id}: {e}")
            return []
    
    async def process_comment(self, issue_id: str, chat_id: int, comment: Dict[str, Any]):
        """Обрабатывает отдельный комментарий и отправляет уведомление"""
        try:
            # Пропускаем комментарии от Telegram бота
            if await self.is_comment_from_telegram_bot(comment):
                logger.debug(f"Пропускаем автоматический комментарий от бота для задачи {issue_id}")
                return False
            
            # Получаем информацию о комментарии
            comment_text = comment.get('text', '')
            comment_id = comment.get('id', '')
            created_time = comment.get('created', '')
            author = await self.youtrack.get_comment_author(comment)
            
            # Проверяем автора - пропускаем комментарии от самого бота
            if author.lower() in ['telegram bot', 'бот telegram', 'telegram']:
                logger.debug(f"Пропускаем комментарий от бота (автор: {author})")
                return False
            
            # Очищаем текст комментария (удаляем лишние пробелы)
            cleaned_text = ' '.join(comment_text.strip().split())
            
            if not cleaned_text:
                logger.debug(f"Пустой комментарий {comment_id} для задачи {issue_id}")
                return False
            
            # Удаляем HTML/маркдаун разметку для лучшей читаемости
            # Удаляем *жирный текст* и `код`
            cleaned_text = re.sub(r'[*`]', '', cleaned_text)
            
            # Удаляем ссылки на задачу
            cleaned_text = re.sub(r'https://yt\.celteh\.net/issue/\S+', '', cleaned_text)
            
            # Форматируем текст - удаляем лишние пустые строки
            lines = [line.strip() for line in cleaned_text.split('\n') if line.strip()]
            cleaned_text = '\n'.join(lines)
            
            # Формируем сообщение для Telegram
            # Обрезаем слишком длинный текст
            if len(cleaned_text) > 1000:
                display_text = cleaned_text[:1000] + "..."
            else:
                display_text = cleaned_text
            
            # Форматируем время
            try:
                if created_time:
                    # Пробуем преобразовать время из YouTrack формата
                    if 'T' in created_time:
                        dt = datetime.fromisoformat(created_time.replace('Z', '+00:00'))
                        time_str = dt.strftime("%Y-%m-%d %H:%M")
                    else:
                        time_str = created_time
                else:
                    time_str = datetime.now().strftime("%Y-%m-%d %H:%M")
            except:
                time_str = "только что"
            
            # Формируем полное сообщение БЕЗ ССЫЛКИ
            message = f"""💬 *Новый комментарий в задаче {issue_id}*

👤 *Автор:* {author}
🕐 *Время:* {time_str}

{display_text}"""
            
            # Добавляем кнопки для быстрых действий
            from telegram import InlineKeyboardMarkup, InlineKeyboardButton
            keyboard = [
                [
                    InlineKeyboardButton("💬 Ответить", callback_data=f"reply_{issue_id}"),
                    InlineKeyboardButton("📋 Мои задачи", callback_data="menu_myissues")
                ],
                [
                    InlineKeyboardButton("✏️ Продолжить", callback_data=f"continue_{issue_id}"),
                    InlineKeyboardButton("❌ Закрыть диалог", callback_data=f"close_{issue_id}")
                ]
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            
            # Отправляем уведомление в Telegram
            try:
                success = await self.bot.application.bot.send_message(
                    chat_id=chat_id,
                    text=message,
                    disable_web_page_preview=True,
                    reply_markup=reply_markup
                )
                
                if success:
                    logger.info(f"✅ Отправлено уведомление о комментарии {comment_id} для задачи {issue_id}")
                    return True
                else:
                    logger.error(f"❌ Не удалось отправить уведомление о комментарии {comment_id}")
                    return False
                    
            except Exception as e:
                logger.error(f"Ошибка отправки уведомления: {e}")
                return False
                
        except Exception as e:
            logger.error(f"❌ Ошибка обработки комментария: {e}", exc_info=True)
            return False
    
    async def is_comment_from_telegram_bot(self, comment: Dict[str, Any]) -> bool:
        """Проверяет, является ли комментарий от бота"""
        try:
            text = comment.get('text', '')
            
            # Признаки комментариев от бота
            bot_indicators = [
                '📱 *Запрос из Telegram*',
                'Telegram Bot',
                '👤 Информация о пользователе:',
                '*🔗 Источник:* Telegram Bot',
                '💬 *Комментарий из Telegram*',
                '*💬 Комментарий из Telegram*',
                '*📅 Дата:*',
                '*👤 Автор:* Telegram Bot',
                '📎 Прикрепленный файл:',
                'Отправлен файл:',
                'Отправлено фото',
                'Отправлен документ:',
                'Отправлено видео',
                'Отправлено аудио',
                'Отправлено голосовое сообщение'
            ]
            
            # Проверяем по содержимому
            for indicator in bot_indicators:
                if indicator in text:
                    return True
            
            # Дополнительные проверки по формату
            lines = text.split('\n')
            if len(lines) > 0:
                first_line = lines[0].strip()
                if first_line.startswith('📱') or first_line.startswith('💬'):
                    return True
            
            return False
            
        except Exception as e:
            logger.error(f"Ошибка проверки комментария на принадлежность боту: {e}")
            return False
    
    def update_issue_last_comment(self, issue_id: str, comment_id: str):
        """Обновляет информацию о последнем проверенном комментарии"""
        try:
            from datetime import datetime
            
            # Получаем текущие данные
            tracked_issues = self.bot._load_tracked_issues()
            
            if issue_id in tracked_issues:
                tracked_issues[issue_id]['last_comment_id'] = comment_id
                tracked_issues[issue_id]['last_comment_time'] = datetime.now().isoformat()
                tracked_issues[issue_id]['last_updated'] = datetime.now().isoformat()
                
                # Сохраняем обновленные данные
                issues_file = self.bot.data_dir / 'tracked_issues.json'
                with open(issues_file, 'w', encoding='utf-8') as f:
                    json.dump(tracked_issues, f, indent=2, ensure_ascii=False)
                
                return True
            return False
        except Exception as e:
            logger.error(f"Ошибка обновления последнего комментария: {e}")
            return False
    
    async def stop(self):
        """Остановка проверки комментариев"""
        self.running = False
        logger.info("🛑 Остановка системы проверки комментариев...")
EOF

# Создаем main.py с поддержкой обоих режимов
print_status "Создание main.py с поддержкой webhook и polling..."
sudo -u "$USER_NAME" cat > "$APP_DIR/main.py" << 'EOF'
#!/usr/bin/env python3
"""
Основной скрипт интеграции Telegram с YouTrack
Поддерживает оба режима: Polling и Webhook
"""

import asyncio
import logging
import sys
import yaml
from pathlib import Path

# Добавляем путь к проекту
sys.path.insert(0, str(Path(__file__).parent))

# Импортируем модули после добавления пути
from app.bot import TelegramBot
from app.youtrack import YouTrackClient
from app.comment_checker import CommentChecker

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/telegram-youtrack/bot.log'),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

async def main():
    """Основная функция запуска"""
    try:
        # Загружаем конфигурацию
        config_path = Path(__file__).parent / 'config' / 'config.yaml'
        with open(config_path, 'r', encoding='utf-8') as f:
            config = yaml.safe_load(f)
        
        # Определяем режим работы
        use_webhook = config.get('server', {}).get('use_webhook', False)
        bot_mode = "Webhook" if use_webhook else "Polling"
        
        logger.info("=" * 60)
        logger.info("🤖 Запуск улучшенного Telegram-YouTrack бота")
        logger.info(f"🌐 YouTrack URL: {config['youtrack']['url']}")
        logger.info(f"🔗 YouTrack API: {config['youtrack']['api_url']}")
        logger.info(f"🤖 Telegram Bot Token: {config['telegram']['token'][:10]}...")
        logger.info(f"💬 Режим работы: {bot_mode}")
        logger.info("📎 Поддержка reply: включена")
        logger.info("📋 Кнопки меню: включены")
        logger.info("=" * 60)
        
        # Инициализируем клиент YouTrack
        youtrack = YouTrackClient(
            base_url=config['youtrack']['api_url'],
            token=config['youtrack']['token'],
            project_id=config['youtrack']['project_id']
        )
        
        # Проверяем подключение к YouTrack
        logger.info("🔗 Проверка подключения к YouTrack...")
        if await youtrack.test_connection():
            logger.info("✅ Подключение к YouTrack: успешно")
        else:
            logger.error("❌ Не удалось подключиться к YouTrack")
            logger.error("Проверьте токен и доступность YouTrack сервера")
            sys.exit(1)
        
        # Инициализируем бота
        bot = TelegramBot(
            telegram_token=config['telegram']['token'],
            youtrack_client=youtrack,
            config=config
        )
        
        # Инициализируем проверку комментариев
        checker = CommentChecker(
            telegram_bot=bot,
            youtrack_client=youtrack,
            config=config
        )
        
        # Запускаем оба процесса параллельно
        logger.info("🚀 Запуск Telegram бота и системы проверки комментариев...")
        
        # Создаем задачи для параллельного выполнения
        bot_task = asyncio.create_task(bot.start())
        checker_task = asyncio.create_task(checker.start())
        
        # Ожидаем завершения обеих задач
        await asyncio.gather(bot_task, checker_task)
        
    except KeyboardInterrupt:
        logger.info("Бот остановлен пользователем")
    except Exception as e:
        logger.error(f"❌ Критическая ошибка при запуске: {e}", exc_info=True)
        sys.exit(1)

if __name__ == '__main__':
    asyncio.run(main())
EOF

# Создаем requirements.txt
sudo -u "$USER_NAME" cat > "$APP_DIR/requirements.txt" << 'EOF'
python-telegram-bot[job-queue]==20.7
aiohttp==3.9.3
PyYAML==6.0.1
requests==2.31.0
python-dotenv==1.0.0
asyncio==3.4.3
urllib3==2.0.7
certifi==2023.7.22
EOF

# 7. Создание конфигурационного файла с учетом выбранного режима
print_status "7. Создание конфигурационного файла..."
cd "$CONFIG_DIR"

if [ "$USE_WEBHOOK" = true ]; then
    cat > config.yaml << EOF
# Конфигурация улучшенного Telegram-YouTrack бота с поддержкой reply
youtrack:
  url: "https://yt.celteh.net"
  api_url: "https://yt.celteh.net/api/"
  token: "$YOUTRACK_TOKEN"
  project_id: "MST"
  telegram_field: "TelegramChatID"
  poll_interval: 30

telegram:
  token: "$TELEGRAM_TOKEN"
  admin_id: $TELEGRAM_ADMIN_ID
  welcome_message: |
    👋 *Добро пожаловать в улучшенную службу поддержки!*
    
    💬 *Новые возможности:*
    • Ответьте (reply) на сообщение о задаче, чтобы добавить комментарий
    • Укажите номер задачи в сообщении (MST-123)
    • Используйте /myissues для просмотра ваших задач
    • Используйте /continue MST-123 для работы с конкретной задачей
    • Используйте /close для завершения текущего диалога
    
    📎 *Можно прикреплять файлы:*
    • Документы, фото, видео, аудио
    • Максимальный размер: 50 МБ
    
    💡 *Как это работает:*
    1. Отправьте сообщение или файл
    2. Бот создаст заявку или определит к какой задаче относится
    3. Ответьте на любое сообщение бота для добавления комментария
    4. Получайте уведомления о новых комментариях
    
    _Мы готовы помочь!_

server:
  host: "0.0.0.0"
  port: 8443
  use_webhook: true
  domain: "$DOMAIN"

logging:
  level: "INFO"
  file: "/var/log/telegram-youtrack/bot.log"
  max_size: 10485760  # 10 MB
  backup_count: 10

files:
  max_size_mb: 50
  allowed_types:
    - image/*
    - application/pdf
    - application/msword
    - application/vnd.openxmlformats-officedocument.wordprocessingml.document
    - application/vnd.ms-excel
    - application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    - text/plain
    - application/zip
    - application/x-rar-compressed
    - audio/*
    - video/*
  upload_dir: "/opt/telegram-youtrack/data/uploads"
  cleanup_after_upload: true

dialogs:
  auto_close_hours: 1  # Автоматическое закрытие диалога после 1 часа неактивности
  max_message_references: 100  # Максимальное количество сохраненных ссылок на сообщения

notifications:
  enabled: true
  check_interval: 30
  skip_bot_comments: true
  max_comment_length: 1000
EOF
else
    cat > config.yaml << EOF
# Конфигурация улучшенного Telegram-YouTrack бота с поддержкой reply
youtrack:
  url: "https://yt.celteh.net"
  api_url: "https://yt.celteh.net/api/"
  token: "$YOUTRACK_TOKEN"
  project_id: "MST"
  telegram_field: "TelegramChatID"
  poll_interval: 30

telegram:
  token: "$TELEGRAM_TOKEN"
  admin_id: $TELEGRAM_ADMIN_ID
  welcome_message: |
    👋 *Добро пожаловать в улучшенную службу поддержки!*
    
    💬 *Новые возможности:*
    • Ответьте (reply) на сообщение о задаче, чтобы добавить комментарий
    • Укажите номер задачи в сообщении (MST-123)
    • Используйте /myissues для просмотра ваших задач
    • Используйте /continue MST-123 для работы с конкретной задачей
    • Используйте /close для завершения текущего диалога
    
    📎 *Можно прикреплять файлы:*
    • Документы, фото, видео, аудио
    • Максимальный размер: 50 МБ
    
    💡 *Как это работает:*
    1. Отправьте сообщение или файл
    2. Бот создаст заявку или определит к какой задаче относится
    3. Ответьте на любое сообщение бота для добавления комментария
    4. Получайте уведомления о новых комментариях
    
    _Мы готовы помочь!_

server:
  host: "0.0.0.0"
  port: 8080
  use_webhook: false

logging:
  level: "INFO"
  file: "/var/log/telegram-youtrack/bot.log"
  max_size: 10485760  # 10 MB
  backup_count: 10

files:
  max_size_mb: 50
  allowed_types:
    - image/*
    - application/pdf
    - application/msword
    - application/vnd.openxmlformats-officedocument.wordprocessingml.document
    - application/vnd.ms-excel
    - application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    - text/plain
    - application/zip
    - application/x-rar-compressed
    - audio/*
    - video/*
  upload_dir: "/opt/telegram-youtrack/data/uploads"
  cleanup_after_upload: true

dialogs:
  auto_close_hours: 1  # Автоматическое закрытие диалога после 1 часа неактивности
  max_message_references: 100  # Максимальное количество сохраненных ссылок на сообщения

notifications:
  enabled: true
  check_interval: 30
  skip_bot_comments: true
  max_comment_length: 1000
EOF
fi

chown "$USER_NAME:$USER_NAME" config.yaml
chmod 600 config.yaml

# 8. Создание виртуального окружения
print_status "8. Создание виртуального окружения Python..."
cd "$APP_DIR"

sudo -u "$USER_NAME" python3 -m venv venv

# Устанавливаем зависимости
sudo -u "$USER_NAME" bash -c "
source $APP_DIR/venv/bin/activate && \
pip install --upgrade pip && \
pip install -r requirements.txt
"

# 9. Создание systemd сервиса
print_status "9. Настройка systemd сервиса..."
cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=Telegram YouTrack Integration Bot with Reply Support and Menu Buttons
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$APP_DIR"
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/main.py
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/service.log
StandardError=append:$LOG_DIR/error.log

# Ограничения безопасности
ProtectSystem=strict
ReadWritePaths=$APP_DIR/data $LOG_DIR
NoNewPrivileges=true
PrivateTmp=true

# Ограничения ресурсов
MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF

# 10. Обновление конфига Nginx для работы с ботом
print_status "10. Обновление конфига Nginx для работы с ботом..."

if [ "$USE_WEBHOOK" = true ]; then
    # Конфигурация для Webhook режима
    cat > "/etc/nginx/sites-available/$DOMAIN" << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # Перенаправляем на HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    # SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # Настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Webhook endpoint для Telegram бота
    location /webhook {
        proxy_pass http://127.0.0.1:8443;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60;
        proxy_send_timeout 60;
        proxy_read_timeout 60;
        
        # Размер загружаемых файлов
        client_max_body_size 50M;
    }
    
    # Статус сервиса (только для чтения)
    location /status {
        alias $LOG_DIR;
        autoindex on;
        autoindex_format html;
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        # Разрешаем только GET запросы
        limit_except GET {
            deny all;
        }
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "OK\\n";
        add_header Content-Type text/plain;
    }
    
    # Запрещаем доступ ко всему остальному
    location / {
        deny all;
        return 404;
    }
    
    # Логирование
    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;
}
EOF
else
    # Конфигурация для Polling режима (только статус)
    cat > "/etc/nginx/sites-available/$DOMAIN" << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # Перенаправляем на HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    # SSL сертификаты
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    
    # Настройки SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Статус сервиса (только для чтения)
    location /status {
        alias $LOG_DIR;
        autoindex on;
        autoindex_format html;
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        # Разрешаем только GET запросы
        limit_except GET {
            deny all;
        }
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "OK\\n";
        add_header Content-Type text/plain;
    }
    
    # Запрещаем доступ ко всему остальному
    location / {
        deny all;
        return 404;
    }
    
    # Логирование
    access_log /var/log/nginx/$DOMAIN.access.log;
    error_log /var/log/nginx/$DOMAIN.error.log;
}
EOF
fi

# Перезагружаем Nginx
nginx -t
systemctl reload nginx

# 11. Настройка пароля для доступа к статусу
print_status "11. Настройка доступа к статусу..."
print_warning "Создайте пароль для доступа к веб-статусу (https://$DOMAIN/status):"
read -p "Введите имя пользователя для веб-доступа: " WEB_USER
echo "Введите пароль для пользователя $WEB_USER:"
htpasswd -c /etc/nginx/.htpasswd "$WEB_USER"

# 12. Настройка firewall
print_status "12. Настройка firewall..."
ufw --force enable
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

if [ "$USE_WEBHOOK" = true ]; then
    ufw allow 8443/tcp comment 'Telegram Bot Webhook'
fi

ufw --force reload

# 13. Настройка ротации логов
print_status "13. Настройка ротации логов..."
cat > /etc/logrotate.d/$SERVICE_NAME << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 $USER_NAME $USER_NAME
    sharedscripts
    postrotate
        systemctl reload $SERVICE_NAME > /dev/null 2>&1 || true
    endscript
}

$APP_DIR/data/*.json {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
    create 0640 $USER_NAME $USER_NAME
}
EOF

# 14. Установка прав
print_status "14. Установка прав доступа..."
chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"
chmod -R 750 "$APP_DIR/app"
chmod -R 755 "$LOG_DIR"
chmod 644 /etc/systemd/system/$SERVICE_NAME.service

# Сделать скрипты исполняемыми
chmod +x "$APP_DIR/app/dialog_manager.py"
chmod +x "$APP_DIR/app/bot.py"
chmod +x "$APP_DIR/app/youtrack.py"
chmod +x "$APP_DIR/app/comment_checker.py"
chmod +x "$APP_DIR/app/callback_handler.py"
chmod +x "$APP_DIR/main.py"

# 15. Запуск сервисов
print_status "15. Запуск сервисов..."
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

# 16. Проверка установки
print_status "16. Проверка установки..."
sleep 8  # Даем время сервису запуститься

if systemctl is-active --quiet $SERVICE_NAME; then
    print_status "✅ Сервис $SERVICE_NAME успешно запущен"
    
    # Проверяем логи
    if [ -f "$LOG_DIR/service.log" ]; then
        print_status "📄 Логи сервиса: tail -f $LOG_DIR/service.log"
        
        # Показываем последние строки лога
        echo ""
        print_info "Последние строки лога:"
        tail -10 "$LOG_DIR/service.log"
    fi
    
    print_status "🔧 Управление сервисом:"
    print_status "   sudo systemctl status $SERVICE_NAME"
    print_status "   sudo systemctl restart $SERVICE_NAME"
    print_status "   sudo journalctl -u $SERVICE_NAME -f"
    
    print_status "🌐 Веб-интерфейс статуса:"
    print_status "   https://$DOMAIN/status"
    print_status "   Логин: $WEB_USER"
    
    print_status "🩺 Health check:"
    print_status "   https://$DOMAIN/health"
    
    if [ "$USE_WEBHOOK" = true ]; then
        print_status "📡 Webhook endpoint:"
        print_status "   https://$DOMAIN/webhook"
    fi
    
else
    print_error "❌ Сервис $SERVICE_NAME не запущен"
    print_error "Проверьте логи: journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi

# 17. Создание скрипта управления
print_status "17. Создание скрипта управления..."
cat > /usr/local/bin/mbsup-manage << 'EOF'
#!/bin/bash
# Скрипт управления Telegram-YouTrack ботом с поддержкой reply и кнопками

SERVICE_NAME="mbsup-bot"
APP_DIR="/opt/telegram-youtrack"
LOG_DIR="/var/log/telegram-youtrack"
USER_NAME="mbsup"

show_help() {
    echo "📱 Управление улучшенным Telegram-YouTrack ботом"
    echo ""
    echo "Использование: mbsup-manage {команда}"
    echo ""
    echo "Команды:"
    echo "  start     - Запустить сервис"
    echo "  stop      - Остановить сервис"
    echo "  restart   - Перезапустить сервис"
    echo "  status    - Статус сервиса"
    echo "  logs      - Просмотр логов в реальном времени"
    echo "  errors    - Просмотр ошибок"
    echo "  stats     - Статистика системы"
    echo "  backup    - Создать резервную копию"
    echo "  update    - Обновить приложение"
    echo "  config    - Показать конфигурацию"
    echo "  cleanup   - Очистить временные файлы"
    echo "  mode      - Показать/изменить режим работы"
    echo "  help      - Показать эту справку"
    echo ""
}

case "$1" in
    start)
        systemctl start $SERVICE_NAME
        echo "✅ Сервис запущен"
        ;;
    stop)
        systemctl stop $SERVICE_NAME
        echo "🛑 Сервис остановлен"
        ;;
    restart)
        systemctl restart $SERVICE_NAME
        echo "🔄 Сервис перезапущен"
        ;;
    status)
        systemctl status $SERVICE_NAME
        ;;
    logs)
        sudo -u $USER_NAME tail -f $LOG_DIR/service.log
        ;;
    errors)
        sudo -u $USER_NAME tail -f $LOG_DIR/error.log
        ;;
    stats)
        echo "📊 Статистика системы:"
        echo ""
        
        # Размер данных
        DATA_SIZE=$(du -sh $APP_DIR/data 2>/dev/null | cut -f1)
        echo "📁 Данные: $DATA_SIZE"
        
        # Количество задач
        if [ -f "$APP_DIR/data/tracked_issues.json" ]; then
            ISSUE_COUNT=$(jq length $APP_DIR/data/tracked_issues.json 2>/dev/null || echo "0")
            echo "📋 Задач: $ISSUE_COUNT"
        fi
        
        # Количество диалогов
        if [ -f "$APP_DIR/data/active_dialogs.json" ]; then
            DIALOG_COUNT=$(jq length $APP_DIR/data/active_dialogs.json 2>/dev/null || echo "0")
            echo "💬 Диалогов: $DIALOG_COUNT"
        fi
        
        # Размер логов
        LOG_SIZE=$(du -sh $LOG_DIR 2>/dev/null | cut -f1)
        echo "📄 Логи: $LOG_SIZE"
        
        # Статус сервиса
        if systemctl is-active --quiet $SERVICE_NAME; then
            echo "✅ Сервис: Активен"
        else
            echo "❌ Сервис: Не активен"
        fi
        
        # Время работы
        UPTIME=$(systemctl status $SERVICE_NAME | grep "Active:" | cut -d';' -f1 | cut -d':' -f2-)
        echo "⏱️  Время работы: $UPTIME"
        ;;
    backup)
        BACKUP_DIR="/var/backups/telegram-youtrack"
        mkdir -p "$BACKUP_DIR"
        BACKUP_FILE="$BACKUP_DIR/backup_$(date +%Y%m%d_%H%M%S).tar.gz"
        
        echo "💾 Создание резервной копии..."
        tar -czf "$BACKUP_FILE" \
            $APP_DIR/data \
            $APP_DIR/config/config.yaml \
            $LOG_DIR/*.log 2>/dev/null
        
        echo "✅ Бэкап создан: $BACKUP_FILE"
        echo "📦 Размер: $(du -h "$BACKUP_FILE" | cut -f1)"
        ;;
    update)
        echo "🔄 Обновление системы..."
        
        systemctl stop $SERVICE_NAME
        
        cd $APP_DIR
        
        # Обновление зависимостей
        sudo -u $USER_NAME bash -c "
            source $APP_DIR/venv/bin/activate
            pip install --upgrade pip
            pip install -r requirements.txt
        "
        
        systemctl start $SERVICE_NAME
        
        echo "✅ Обновление завершено"
        ;;
    config)
        echo "⚙️ Текущая конфигурация:"
        echo ""
        
        if [ -f "$APP_DIR/config/config.yaml" ]; then
            # Показываем безопасные части конфигурации
            grep -E "^(  (url|project_id|admin_id|max_size_mb|level|use_webhook|port)|[a-z_]+:)" $APP_DIR/config/config.yaml | \
                sed 's/token:.*/token: ********/g' | \
                sed 's/admin_id:.*/admin_id: ********/g'
        else
            echo "❌ Конфигурационный файл не найден"
        fi
        ;;
    mode)
        if [ -f "$APP_DIR/config/config.yaml" ]; then
            CURRENT_MODE=$(grep "use_webhook:" "$APP_DIR/config/config.yaml" | awk '{print $2}')
            if [ "$CURRENT_MODE" = "true" ]; then
                echo "📡 Текущий режим: Webhook"
                echo "Порт: 8443"
                echo "Webhook URL: https://$(grep "domain:" "$APP_DIR/config/config.yaml" | awk '{print $2'})/webhook"
            else
                echo "🔄 Текущий режим: Polling"
            fi
            
            echo ""
            read -p "Хотите изменить режим? (y/n): " CHANGE_MODE
            if [ "$CHANGE_MODE" = "y" ] || [ "$CHANGE_MODE" = "Y" ]; then
                echo "1) Polling (рекомендуется для тестирования)"
                echo "2) Webhook (рекомендуется для продакшена)"
                read -p "Выберите режим (1 или 2): " NEW_MODE
                
                if [ "$NEW_MODE" = "1" ]; then
                    sed -i 's/use_webhook: true/use_webhook: false/' "$APP_DIR/config/config.yaml"
                    echo "✅ Режим изменен на Polling"
                    echo "⚠️  Для применения изменений перезапустите сервис:"
                    echo "   sudo systemctl restart $SERVICE_NAME"
                elif [ "$NEW_MODE" = "2" ]; then
                    sed -i 's/use_webhook: false/use_webhook: true/' "$APP_DIR/config/config.yaml"
                    echo "✅ Режим изменен на Webhook"
                    echo "⚠️  Для применения изменений перезапустите сервис:"
                    echo "   sudo systemctl restart $SERVICE_NAME"
                else
                    echo "❌ Неверный выбор. Режим не изменен."
                fi
            fi
        else
            echo "❌ Конфигурационный файл не найден"
        fi
        ;;
    cleanup)
        echo "🧹 Очистка временных файлов..."
        
        # Удаляем старые файлы из uploads (старше 7 дней)
        find $APP_DIR/data/uploads -type f -mtime +7 -delete 2>/dev/null
        
        # Очищаем старые логи (система logrotate уже делает это)
        echo "✅ Временные файлы очищены"
        ;;
    help|*)
        show_help
        ;;
esac
EOF

chmod +x /usr/local/bin/mbsup-manage

# 18. Создание cron заданий
print_status "18. Настройка cron заданий..."
cat > /etc/cron.d/mbsup << EOF
# Очистка старых файлов (каждый день в 3:00)
0 3 * * * $USER_NAME find $APP_DIR/data/uploads -type f -mtime +7 -delete 2>/dev/null

# Резервное копирование (каждое воскресенье в 2:00)
0 2 * * 0 $USER_NAME /usr/local/bin/mbsup-manage backup >/dev/null 2>&1

# Проверка статуса сервиса (каждый час)
0 * * * * root systemctl is-active --quiet $SERVICE_NAME || systemctl restart $SERVICE_NAME
EOF

# 19. Итог
print_status "=============================================="
print_status "✅ Установка завершена успешно!"
print_status "=============================================="
print_status "🌐 Домен: https://$DOMAIN"
print_status "🤖 Сервис: $SERVICE_NAME"
print_status "📁 Директория: $APP_DIR"
print_status "📄 Логи: $LOG_DIR"
print_status "📡 Режим работы: $BOT_MODE_NAME"
print_status ""
print_status "🔧 Управление:"
print_status "   mbsup-manage status   # статус сервиса"
print_status "   mbsup-manage logs     # логи в реальном времени"
print_status "   mbsup-manage stats    # статистика"
print_status "   mbsup-manage backup   # резервная копия"
print_status "   mbsup-manage mode     # показать/изменить режим работы"
print_status ""
print_status "🌐 Веб-доступ:"
print_status "   Статус: https://$DOMAIN/status"
print_status "   Логин: $WEB_USER"
print_status "   Health check: https://$DOMAIN/health"

if [ "$USE_WEBHOOK" = true ]; then
    print_status "   Webhook: https://$DOMAIN/webhook"
    print_status "   Webhook порт: 8443 (внутренний)"
fi

print_status ""
print_status "💬 Новые возможности:"
print_status "   • Inline-кнопки меню для навигации"
print_status "   • Reply к сообщениям для добавления комментариев"
print_status "   • Автоматическое определение контекста"
print_status "   • Управление диалогами (/myissues, /continue, /close)"
print_status "   • Прикрепление файлов к существующим задачам"
print_status "   • Улучшенная фильтрация уведомлений (не дублируются)"
print_status "   • Кнопки быстрых действий в уведомлениях"
print_status "   • Поддержка двух режимов работы: Polling и Webhook"
print_status ""
print_status "📋 Следующие шаги:"
print_status "1. Найдите бота в Telegram и отправьте /start"
print_status "2. Используйте кнопки меню для навигации"
print_status "3. Отправьте тестовое сообщение"
print_status "4. Ответьте (reply) на сообщение бота"
print_status "5. Проверьте создание задач в YouTrack"
print_status "6. Ответьте на задачу в YouTrack"
print_status "7. Получите уведомление с кнопками в Telegram"
print_status ""
print_status "⚠️  Важные заметки:"

if [ "$USE_WEBHOOK" = true ]; then
    print_status "   • Бот работает в режиме Webhook (продакшен)"
    print_status "   • Nginx проксирует запросы на порт 8443"
    print_status "   • SSL сертификаты настроены автоматически"
else
    print_status "   • Бот работает в режиме Polling (тестирование)"
    print_status "   • Для продакшена рекомендуется переключиться на Webhook:"
    print_status "     mbsup-manage mode"
fi

print_status "=============================================="

# 20. Создание тестового скрипта
print_status "19. Создание тестового скрипта..."
cat > "$APP_DIR/test_bot.py" << 'EOF'
#!/usr/bin/env python3
"""
Тестовый скрипт для проверки работы бота с кнопками
"""

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import yaml
from pathlib import Path
from app.youtrack import YouTrackClient

async def test_youtrack():
    """Тестирование подключения к YouTrack"""
    config_path = Path(__file__).parent / 'config' / 'config.yaml'
    with open(config_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    
    youtrack = YouTrackClient(
        base_url=config['youtrack']['api_url'],
        token=config['youtrack']['token'],
        project_id=config['youtrack']['project_id']
    )
    
    print("🔗 Тестирование подключения к YouTrack...")
    if await youtrack.test_connection():
        print("✅ Подключение успешно")
    else:
        print("❌ Не удалось подключиться")
        return False
    
    print("\n📋 Тестирование создания задачи...")
    test_result = await youtrack.create_ticket_from_telegram(
        user_id="test_user",
        user_name="Test User",
        message="Тестовое сообщение для проверки работы системы с кнопками"
    )
    
    if test_result['success']:
        print(f"✅ Тестовая задача создана: {test_result['ticket_id']}")
        print(f"🔗 Ссылка: {test_result['ticket_url']}")
    else:
        print(f"❌ Ошибка создания задачи: {test_result.get('error')}")
    
    return test_result['success']

if __name__ == '__main__':
    import asyncio
    
    print("🧪 Тестирование системы Telegram-YouTrack бота с кнопками")
    print("=" * 50)
    
    try:
        success = asyncio.run(test_youtrack())
        
        print("\n" + "=" * 50)
        if success:
            print("✅ Все тесты пройдены успешно!")
        else:
            print("❌ Тесты завершились с ошибками")
            sys.exit(1)
            
    except Exception as e:
        print(f"❌ Исключение при тестировании: {e}")
        sys.exit(1)
EOF

chmod +x "$APP_DIR/test_bot.py"
chown "$USER_NAME:$USER_NAME" "$APP_DIR/test_bot.py"

print_status "\n🧪 Тестирование системы:"
print_status "   sudo -u $USER_NAME $APP_DIR/venv/bin/python $APP_DIR/test_bot.py"

print_status "\n🎉 Установка завершена! Удачной работы!"
