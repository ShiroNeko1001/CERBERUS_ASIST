from __future__ import annotations

import hashlib
import hmac
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final

try:
    import requests
except ImportError:  # pragma: no cover - environment dependent
    requests = None

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - environment dependent
    def load_dotenv() -> bool:
        return False

try:
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
except ImportError as exc:  # pragma: no cover - environment dependent
    InlineKeyboardButton = None
    InlineKeyboardMarkup = None
    Update = Any
    Application = None
    CallbackQueryHandler = None
    CommandHandler = None
    ContextTypes = Any
    MessageHandler = None
    filters = None
    TELEGRAM_IMPORT_ERROR = exc
else:
    TELEGRAM_IMPORT_ERROR = None

load_dotenv()


@dataclass
class BotSettings:
    token: str | None
    llama_api: str
    base_dir: Path
    state_dir: Path
    heartbeat_file: Path
    pair_file: Path
    pair_ts_file: Path
    audit_file: Path
    pair_ttl_sec: int
    command_secret: str
    errors: list[str]


def load_settings() -> BotSettings:
    errors: list[str] = []
    base_dir = Path(os.getenv("CERBERUS_ASIST_BASE", "/opt/cerberus_asist"))
    state_dir = base_dir / "state"
    token = os.getenv("TELEGRAM_TOKEN")
    llama_api = os.getenv("LLAMA_API", "http://127.0.0.1:8080/v1")
    if not token:
        errors.append("TELEGRAM_TOKEN missing")
    if not llama_api:
        errors.append("LLAMA_API missing")

    try:
        pair_ttl_sec = int(os.getenv("PAIR_TTL_SEC", "86400"))
    except ValueError:
        pair_ttl_sec = 86400
        errors.append("PAIR_TTL_SEC invalid, using default 86400")

    return BotSettings(
        token=token,
        llama_api=llama_api,
        base_dir=base_dir,
        state_dir=state_dir,
        heartbeat_file=state_dir / "heartbeat.txt",
        pair_file=state_dir / "controller.id",
        pair_ts_file=state_dir / "controller.ts",
        audit_file=base_dir / "audit.log",
        pair_ttl_sec=pair_ttl_sec,
        command_secret=os.getenv("COMMAND_SECRET", ""),
        errors=errors,
    )


SETTINGS: Final[BotSettings] = load_settings()
LLAMA_API: Final[str] = SETTINGS.llama_api
TOKEN: Final[str | None] = SETTINGS.token
BASE_DIR: Final[Path] = SETTINGS.base_dir
STATE_DIR: Final[Path] = SETTINGS.state_dir
HEARTBEAT_FILE: Final[Path] = SETTINGS.heartbeat_file
PAIR_FILE: Final[Path] = SETTINGS.pair_file
PAIR_TS_FILE: Final[Path] = SETTINGS.pair_ts_file
AUDIT_FILE: Final[Path] = SETTINGS.audit_file
PAIR_TTL_SEC: Final[int] = SETTINGS.pair_ttl_sec
COMMAND_SECRET: Final[str] = SETTINGS.command_secret

STATE_DIR.mkdir(parents=True, exist_ok=True)


def audit(message: str) -> None:
    AUDIT_FILE.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{message}\n")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""


def current_chat_id(update: Any) -> str:
    return str(getattr(update.effective_chat, "id", "unknown"))


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


def is_paired(update: Any) -> bool:
    return paired_chat_id() == current_chat_id(update) and pair_age_ok()


def signed_ok(update: Any, token: str | None) -> bool:
    if not COMMAND_SECRET:
        return True
    if not token or not getattr(update, "message", None) or not getattr(update.message, "text", None):
        return False
    command = update.message.text.split(maxsplit=1)[0]
    payload = f"{current_chat_id(update)}:{command}"
    digest = hmac.new(COMMAND_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()[:16]
    return hmac.compare_digest(digest, token)


async def reply(update: Any, text: str) -> None:
    if getattr(update, "message", None):
        await update.message.reply_text(text)


def build_menu_keyboard() -> Any:
    if InlineKeyboardMarkup is None or InlineKeyboardButton is None:
        return None
    return InlineKeyboardMarkup(
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


MENU_KEYBOARD = build_menu_keyboard()


async def send_main_menu(update: Any, context: Any) -> None:
    if getattr(update, "message", None):
        await update.message.reply_text(
            "Selamat datang di Cerberus Asist! Pilih menu:",
            reply_markup=MENU_KEYBOARD,
        )
    audit(f"start chat={current_chat_id(update)} user={getattr(update.effective_user, 'id', 'unknown')}")


async def start(update: Any, context: Any) -> None:
    await send_main_menu(update, context)


async def help_cmd(update: Any, context: Any) -> None:
    await send_main_menu(update, context)
    audit(f"help chat={current_chat_id(update)}")


async def pair(update: Any, context: Any) -> None:
    token = context.args[0] if context.args else ""
    if not signed_ok(update, token):
        await reply(update, "Token pairing tidak valid.")
        audit(f"pair denied chat={current_chat_id(update)}")
        return

    cid = current_chat_id(update)
    PAIR_FILE.write_text(cid, encoding="utf-8")
    PAIR_TS_FILE.write_text(str(time.time()), encoding="utf-8")
    await reply(update, f"Perangkat berhasil dipasangkan: {cid}")
    audit(f"pair chat={cid} user={getattr(update.effective_user, 'id', 'unknown')}")


async def status(update: Any, context: Any) -> None:
    if not is_paired(update):
        await send_main_menu(update, context)
        audit(f"status denied chat={current_chat_id(update)}")
        return

    await reply(update, f"✅ Status OK.\n🎯 Target API: {LLAMA_API}")
    audit(f"status ok chat={current_chat_id(update)}")


async def heartbeat(update: Any, context: Any) -> None:
    if not is_paired(update):
        await reply(update, "Perangkat belum dipasangkan.")
        audit(f"heartbeat denied chat={current_chat_id(update)}")
        return

    token = context.args[0] if context.args else ""
    if not signed_ok(update, token):
        await reply(update, "Token heartbeat tidak valid.")
        audit(f"heartbeat denied token chat={current_chat_id(update)}")
        return

    HEARTBEAT_FILE.write_text(current_chat_id(update), encoding="utf-8")
    PAIR_TS_FILE.write_text(str(time.time()), encoding="utf-8")
    await reply(update, "Heartbeat tersimpan.")
    audit(f"heartbeat ok chat={current_chat_id(update)}")


def safe_chat_completion(message: str, settings: BotSettings | None = None) -> tuple[bool, str]:
    if requests is None:
        return False, "Layanan model belum siap atau dependensi tidak tersedia."

    target_api = settings.llama_api if settings else LLAMA_API
    try:
        response = requests.post(
            f"{target_api}/chat/completions",
            json={
                "model": "local",
                "messages": [
                    {"role": "system", "content": "Jawab singkat, jelas, dan profesional dalam bahasa Indonesia."},
                    {"role": "user", "content": message},
                ],
                "temperature": 0.2,
            },
            timeout=60,
        )
        response.raise_for_status()
        payload = response.json()
        content = payload.get("choices", [{}])[0].get("message", {}).get("content", "")
        if not content:
            return False, "Layanan model mengembalikan respons kosong."
        return True, content
    except Exception as exc:  # pragma: no cover - network dependent
        audit(f"chat error err={type(exc).__name__}")
        return False, "Layanan model belum siap atau respons tidak valid."


async def chat(update: Any, context: Any) -> None:
    if not is_paired(update):
        await reply(update, "Perangkat belum dipasangkan.")
        audit(f"chat denied chat={current_chat_id(update)}")
        return

    if not getattr(update, "message", None) or not getattr(update.message, "text", None):
        await reply(update, "Pesan tidak valid.")
        return

    message = update.message.text.strip()
    audit(f"chat ok chat={current_chat_id(update)} msg={message[:120]}")

    ok, text = safe_chat_completion(message)
    if not ok:
        await reply(update, text)
        return

    await reply(update, text[:4096])


async def install_menu(update: Any, context: Any) -> None:
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
    if getattr(update, "message", None):
        await update.message.reply_text(
            "📦 Pilih komponen yang ingin diinstal:",
            reply_markup=keyboard,
        )
    audit(f"install_menu chat={current_chat_id(update)}")


async def button_callback(update: Any, context: Any) -> None:
    query = getattr(update, "callback_query", None)
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
        await query.edit_message_text(text="⚙️ Fitur konfigurasi akan segera tersedia.")
    elif data == "status":
        if is_paired(update):
            await query.edit_message_text(text=f"✅ Status OK.\n🎯 Target API: {LLAMA_API}")
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

    audit(f"button callback={data} chat={current_chat_id(update)}")


async def install(update: Any, context: Any) -> None:
    await install_menu(update, context)


def main() -> int:
    if SETTINGS.errors and not TOKEN:
        print("Bot tidak bisa dimulai karena konfigurasi belum lengkap:", file=sys.stderr)
        for error in SETTINGS.errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    if TELEGRAM_IMPORT_ERROR is not None:
        print(
            f"Dependensi telegram belum tersedia: {TELEGRAM_IMPORT_ERROR}\n"
            "Install dengan: pip install -r src/bot/requirements.txt",
            file=sys.stderr,
        )
        return 1

    if requests is None:
        print("Dependensi requests belum tersedia.", file=sys.stderr)
        return 1

    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler("pair", pair))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("heartbeat", heartbeat))
    app.add_handler(CommandHandler("install", install))
    app.add_handler(CallbackQueryHandler(button_callback))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, chat))
    try:
        app.run_polling()
    except Exception as exc:  # pragma: no cover - runtime dependent
        print(f"Bot gagal berjalan: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
