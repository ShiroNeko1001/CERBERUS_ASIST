from __future__ import annotations

import hashlib
import hmac
import os
import time
from pathlib import Path
from typing import Final

import requests
from dotenv import load_dotenv
# pyrefly: ignore [missing-import]
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
# pyrefly: ignore [missing-import]
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

load_dotenv()

LLAMA_API: Final[str] = os.getenv("LLAMA_API", "http://127.0.0.1:8080/v1")
TOKEN: Final[str | None] = os.getenv("TELEGRAM_TOKEN")
BASE_DIR: Final[Path] = Path(os.getenv("CERBERUS_ASIST_BASE", "/opt/cerberus_asist"))
STATE_DIR: Final[Path] = BASE_DIR / "state"
HEARTBEAT_FILE: Final[Path] = STATE_DIR / "heartbeat.txt"
PAIR_FILE: Final[Path] = STATE_DIR / "controller.id"
PAIR_TS_FILE: Final[Path] = STATE_DIR / "controller.ts"
AUDIT_FILE: Final[Path] = BASE_DIR / "audit.log"
PAIR_TTL_SEC: Final[int] = int(os.getenv("PAIR_TTL_SEC", "86400"))
COMMAND_SECRET: Final[str] = os.getenv("COMMAND_SECRET", "")

if not TOKEN:
    raise RuntimeError("TELEGRAM_TOKEN missing")

STATE_DIR.mkdir(parents=True, exist_ok=True)


def audit(message: str) -> None:
    AUDIT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{message}\n")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


def current_chat_id(update: Update) -> str:
    return str(update.effective_chat.id)


def paired_chat_id() -> str:
    return read_text(PAIR_FILE)


def pair_age_ok() -> bool:
    raw = read_text(PAIR_TS_FILE)
    if not raw:
        return False
    try:
        age = time.time() - float(raw)
    except ValueError:
        return False
    return age <= PAIR_TTL_SEC


def is_paired(update: Update) -> bool:
    return paired_chat_id() == current_chat_id(update) and pair_age_ok()


def signed_ok(update: Update, token: str | None) -> bool:
    if not COMMAND_SECRET:
        return True
    if not token or not update.message or not update.message.text:
        return False
    command = update.message.text.split(maxsplit=1)[0]
    payload = f"{current_chat_id(update)}:{command}"
    digest = hmac.new(COMMAND_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()[:16]
    return hmac.compare_digest(digest, token)


async def reply(update: Update, text: str) -> None:
    if update.message:
        await update.message.reply_text(text)


MENU_KEYBOARD = InlineKeyboardMarkup(
    [
        [
            InlineKeyboardButton("📦 Instalasi", callback_data="install"),
            InlineKeyboardButton("⚙️ Konfigurasi", callback_data="config"),
        ],
        [
            InlineKeyboardButton("📋 Status", callback_data="status"),
            InlineKeyboardButton("❓ Bantuan", callback_data="help"),
        ],
    ]
)


async def send_main_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.message:
        await update.message.reply_text(
            "Selamat datang di Cerberus Asist! Pilih menu:",
            reply_markup=MENU_KEYBOARD,
        )
    audit(f"start chat={update.effective_chat.id} user={update.effective_user.id}")


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await send_main_menu(update, context)


async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await send_main_menu(update, context)
    audit(f"help chat={update.effective_chat.id}")


async def pair(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    token = context.args[0] if context.args else ""
    if not signed_ok(update, token):
        await reply(update, "Token pairing tidak valid.")
        audit(f"pair denied chat={update.effective_chat.id}")
        return

    cid = current_chat_id(update)
    PAIR_FILE.write_text(cid, encoding="utf-8")
    PAIR_TS_FILE.write_text(str(time.time()), encoding="utf-8")
    await reply(update, f"Perangkat berhasil dipasangkan: {cid}")
    audit(f"pair chat={cid} user={update.effective_user.id}")


async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_paired(update):
        await send_main_menu(update, context)
        audit(f"status denied chat={update.effective_chat.id}")
        return

    await reply(update, f"✅ Status OK.\n🎯 Target API: {LLAMA_API}")
    audit(f"status ok chat={update.effective_chat.id}")


async def heartbeat(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_paired(update):
        await reply(update, "Perangkat belum dipasangkan.")
        audit(f"heartbeat denied chat={update.effective_chat.id}")
        return

    token = context.args[0] if context.args else ""
    if not signed_ok(update, token):
        await reply(update, "Token heartbeat tidak valid.")
        audit(f"heartbeat denied token chat={update.effective_chat.id}")
        return

    HEARTBEAT_FILE.write_text(current_chat_id(update), encoding="utf-8")
    PAIR_TS_FILE.write_text(str(time.time()), encoding="utf-8")
    await reply(update, "Heartbeat tersimpan.")
    audit(f"heartbeat ok chat={update.effective_chat.id}")


async def chat(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_paired(update):
        await reply(update, "Perangkat belum dipasangkan.")
        audit(f"chat denied chat={update.effective_chat.id}")
        return

    if not update.message or not update.message.text:
        await reply(update, "Pesan tidak valid.")
        return

    message = update.message.text.strip()
    audit(f"chat ok chat={update.effective_chat.id} msg={message[:120]}")

    try:
        response = requests.post(
            f"{LLAMA_API}/chat/completions",
            json={
                "model": "local",
                "messages": [
                    {"role": "system", "content": "Jawab singkat, jelas, dan profesional dalam bahasa Indonesia."},
                    {"role": "user", "content": message},
                ],
                "temperature": 0.2,
            },
            timeout=120,
        )
        response.raise_for_status()
        text = response.json()["choices"][0]["message"]["content"]
    except (requests.RequestException, KeyError, IndexError, ValueError) as exc:
        audit(f"chat error chat={update.effective_chat.id} err={type(exc).__name__}")
        await reply(update, "Layanan model belum siap atau respons tidak valid.")
        return

    await reply(update, text[:4096])


async def install_menu(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    keyboard = InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("🖥️ Server", callback_data="install_server"),
                InlineKeyboardButton("🐳 Docker", callback_data="install_docker"),
            ],
            [
                InlineKeyboardButton("🤖 Bot", callback_data="install_bot"),
                InlineKeyboardButton("🌐 Dashboard", callback_data="install_dashboard"),
            ],
            [InlineKeyboardButton("◀️ Kembali", callback_data="back_main")],
        ]
    )
    if update.message:
        await update.message.reply_text(
            "📦 Pilih komponen yang ingin diinstal:",
            reply_markup=keyboard,
        )
    audit(f"install_menu chat={update.effective_chat.id}")


async def button_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if not query:
        return

    await query.answer()
    data = query.data

    if data == "install":
        keyboard = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton("🖥️ Server", callback_data="install_server"),
                    InlineKeyboardButton("🐳 Docker", callback_data="install_docker"),
                ],
                [
                    InlineKeyboardButton("🤖 Bot", callback_data="install_bot"),
                    InlineKeyboardButton("🌐 Dashboard", callback_data="install_dashboard"),
                ],
                [InlineKeyboardButton("◀️ Kembali", callback_data="back_main")],
            ]
        )
        await query.edit_message_text(
            text="📦 Pilih komponen yang ingin diinstal:", reply_markup=keyboard
        )
    elif data == "config":
        await query.edit_message_text(
            text="⚙️ Fitur konfigurasi akan segera tersedia."
        )
    elif data == "status":
        if is_paired(update):
            await query.edit_message_text(
                text=f"✅ Status OK.\n🎯 Target API: {LLAMA_API}"
            )
        else:
            await query.edit_message_text(text="❌ Perangkat belum dipasangkan.")
    elif data == "help":
        await query.edit_message_text(
            text="Perintah tersedia:\n/start - Menu utama\n/pair - Pasangkan perangkat\n/status - Cek status\n/heartbeat - Kirim heartbeat\n/install - Menu instalasi"
        )
    elif data == "back_main":
        await query.edit_message_text(
            text="Selamat datang di Cerberus Asist! Pilih menu:",
            reply_markup=MENU_KEYBOARD,
        )
    elif data == "install_server":
        await query.edit_message_text(
            text="🖥️ Instalasi server:\n\n"
                 "1. Pastikan Python 3.9+ terinstall\n"
                 "2. Install dependensi: pip install -r requirements.txt\n"
                 "3. Salin file .env.example ke .env\n"
                 "4. Konfigurasi token di .env\n"
                 "5. Jalankan dengan ./run.sh"
        )
    elif data == "install_docker":
        await query.edit_message_text(
            text="🐳 Instalasi Docker:\n\n"
                 "1. Install Docker: curl -fsSL https://get.docker.com | sh\n"
                 "2. Salin file docker-compose.yml.example\n"
                 "3. Jalankan: docker-compose up -d\n"
                 "4. Lihat logs: docker-compose logs -f"
        )
    elif data == "install_bot":
        await query.edit_message_text(
            text="🤖 Instalasi Bot Telegram:\n\n"
                 "1. Buat bot via @BotFather\n"
                 "2. Ambil token bot\n"
                 "3. Set TELEGRAM_TOKEN di file .env\n"
                 "4. Jalankan python src/bot/telegram_bot.py\n"
                 "5. Kirim perintah /start di Telegram"
        )
    elif data == "install_dashboard":
        await query.edit_message_text(
            text="🌐 Instalasi Dashboard:\n\n"
                 "1. Install dependensi dashboard\n"
                 "2. Konfigurasi port di config/\n"
                 "3. Jalankan python src/dashboard/dashboard.py\n"
                 "4. Buka http://localhost:8000"
        )

    audit(f"button callback={data} chat={update.effective_chat.id}")


async def install(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await install_menu(update, context)


def main() -> None:
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler("pair", pair))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("heartbeat", heartbeat))
    app.add_handler(CommandHandler("install", install))
    app.add_handler(CallbackQueryHandler(button_callback))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, chat))
    app.run_polling()


if __name__ == "__main__":
    main()
