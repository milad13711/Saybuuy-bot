# -*- coding: utf-8 -*-
"""
بات فروش/بازاریابی محصول W1 Ultra Mini برای پیام‌رسان بله (Bale).

روش کار: Long Polling روی getUpdates (نیازی به سرور با آدرس عمومی/HTTPS
نیست؛ کافیه این اسکریپت روی هر سیستمی که به اینترنت وصله اجرا بشه).

نحوه‌ی اجرا:
    1) pip install -r requirements.txt
    2) مقدار BALE_BOT_TOKEN رو در فایل .env (کنار همین فایل) قرار بده
       یا به‌صورت متغیر محیطی export کن.
    3) python bot.py

برای توقف: Ctrl+C
"""

import os
import time
import logging

import requests
from dotenv import load_dotenv

import messages as msg

load_dotenv()

BOT_TOKEN = os.getenv("BALE_BOT_TOKEN", "").strip()
if not BOT_TOKEN:
    raise SystemExit(
        "❌ توکن بات پیدا نشد. مقدار BALE_BOT_TOKEN رو در فایل .env قرار بده."
    )

API_BASE = f"https://tapi.bale.ai/bot{BOT_TOKEN}"
REQUEST_TIMEOUT = 30  # ثانیه؛ برای getUpdates با long polling بیشتره (پایین‌تر ست می‌شه)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
log = logging.getLogger("saybuuy-bot")


# ---------------------------------------------------------------------------
# کمک‌تابع‌های ارتباط با Bale Bot API
# ---------------------------------------------------------------------------

def api_call(method: str, payload: dict | None = None, timeout: int = REQUEST_TIMEOUT):
    url = f"{API_BASE}/{method}"
    try:
        resp = requests.post(url, json=payload or {}, timeout=timeout)
        data = resp.json()
        if not data.get("ok", False):
            log.warning("API error on %s: %s", method, data)
        return data
    except requests.RequestException as exc:
        log.error("Network error calling %s: %s", method, exc)
        return None


def main_keyboard():
    """کیبورد اینلاین اصلی: همیشه دکمه‌ی خرید (لینک مستقیم به لندینگ) بالاست."""
    return {
        "inline_keyboard": [
            [{"text": msg.BTN_BUY, "url": msg.LANDING_URL}],
            [
                {"text": msg.BTN_FEATURES, "callback_data": "features"},
                {"text": msg.BTN_WHY, "callback_data": "why_now"},
            ],
            [{"text": msg.BTN_PRICE, "callback_data": "price"}],
        ]
    }


def back_keyboard():
    return {
        "inline_keyboard": [
            [{"text": msg.BTN_BUY, "url": msg.LANDING_URL}],
            [{"text": msg.BTN_BACK, "callback_data": "back"}],
        ]
    }


def send_message(chat_id, text, keyboard=None):
    # نکته: بله برخلاف تلگرام پارامتر parse_mode نداره؛ متن هر پیام همیشه
    # با فرمت اختصاصی خودِ بله (که در messages.py رعایت شده) قالب‌بندی می‌شه.
    payload = {
        "chat_id": chat_id,
        "text": text,
    }
    if keyboard:
        payload["reply_markup"] = keyboard
    return api_call("sendMessage", payload)


def answer_callback(callback_query_id, text=None):
    payload = {"callback_query_id": callback_query_id}
    if text:
        payload["text"] = text
    api_call("answerCallbackQuery", payload)


# ---------------------------------------------------------------------------
# منطق مکالمه
# ---------------------------------------------------------------------------

def handle_command(chat_id, text):
    command = text.split()[0].lower()

    if command in ("/start", "start"):
        send_message(chat_id, msg.WELCOME, main_keyboard())
    elif command == "/price":
        send_message(chat_id, msg.PRICE_INFO, back_keyboard())
    elif command == "/buy":
        send_message(chat_id, msg.BUY_FOLLOWUP, back_keyboard())
    elif command == "/help":
        send_message(chat_id, msg.COMMAND_HELP, main_keyboard())
    else:
        send_message(chat_id, msg.FALLBACK, main_keyboard())


def handle_text_message(message):
    chat_id = message["chat"]["id"]
    text = message.get("text", "") or ""

    if text.startswith("/"):
        handle_command(chat_id, text)
    else:
        # هر پیام متنی دیگه‌ای رو به سمت پیشنهاد اصلی هدایت می‌کنیم
        send_message(chat_id, msg.FALLBACK, main_keyboard())


def handle_callback_query(callback_query):
    data = callback_query.get("data", "")
    chat_id = callback_query["message"]["chat"]["id"]
    callback_id = callback_query["id"]

    if data == "features":
        send_message(chat_id, msg.FEATURES, back_keyboard())
    elif data == "why_now":
        send_message(chat_id, msg.WHY_NOW, back_keyboard())
    elif data == "price":
        send_message(chat_id, msg.PRICE_INFO, back_keyboard())
    elif data == "back":
        send_message(chat_id, msg.WELCOME, main_keyboard())
    else:
        send_message(chat_id, msg.FALLBACK, main_keyboard())

    # به بله اطلاع می‌دیم که کال‌بک پردازش شد (لودینگ روی دکمه رو قطع می‌کنه)
    answer_callback(callback_id)


def process_update(update: dict):
    if "message" in update and "text" in update["message"]:
        handle_text_message(update["message"])
    elif "callback_query" in update:
        handle_callback_query(update["callback_query"])
    # سایر انواع آپدیت (عکس، استیکر و ...) فعلاً نادیده گرفته می‌شن


# ---------------------------------------------------------------------------
# حلقه‌ی اصلی Long Polling
# ---------------------------------------------------------------------------

def run():
    log.info("بات در حال اجراست (Long Polling)... برای توقف Ctrl+C بزن.")
    offset = 0
    while True:
        try:
            data = api_call(
                "getUpdates",
                {"offset": offset, "timeout": 25},
                timeout=35,
            )
            if not data or not data.get("ok"):
                time.sleep(3)
                continue

            for update in data.get("result", []):
                offset = update["update_id"] + 1
                try:
                    process_update(update)
                except Exception:
                    log.exception("خطا در پردازش آپدیت: %s", update)

        except KeyboardInterrupt:
            log.info("بات متوقف شد.")
            break
        except Exception:
            log.exception("خطای غیرمنتظره در حلقه‌ی اصلی؛ ۵ ثانیه بعد دوباره تلاش می‌شه.")
            time.sleep(5)


if __name__ == "__main__":
    run()
