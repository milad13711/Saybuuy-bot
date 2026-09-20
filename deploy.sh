#!/usr/bin/env bash
# =============================================================================
# اسکریپت نصب و راه‌اندازی خودکار بات بله Saybuuy (W1 Ultra Mini) روی VPS
# =============================================================================
# نحوه‌ی استفاده روی سرور (اوبونتو/دبیان، با دسترسی sudo):
#   1) این فایل رو روی سرور آپلود کن (مثلاً با scp یا از طریق پنل هاست)
#      یا مستقیم دانلودش کن:
#      curl -fsSL https://raw.githubusercontent.com/milad13711/Saybuuy-bot/main/deploy.sh -o deploy.sh
#   2) اجرا کن:  sudo bash deploy.sh
#   3) اگه اولین باره، توکن بات رو وقتی ازت پرسید وارد کن (یا از پیش در
#      متغیر محیطی BALE_BOT_TOKEN بذار). اگه قبلاً یک بار اجرا کرده باشی،
#      این اسکریپت خودکار از توکن قبلی (که در .env ذخیره شده) استفاده
#      می‌کنه و دیگه چیزی ازت نمی‌پرسه — یعنی برای هر آپدیت کد، فقط کافیه
#      همین دو خط بالا رو دوباره اجرا کنی.
#
# این اسکریپت:
#   - پایتون/pip (در صورت نبود) رو نصب می‌کنه
#   - پروژه رو در /opt/saybuuy-bale-bot می‌سازه (و در اجراهای بعدی، فقط
#     کد رو آپدیت می‌کنه)
#   - یک virtualenv جدا و پکیج‌های لازم رو نصب می‌کنه
#   - یک systemd service می‌سازه تا بات ۲۴ساعته اجرا بشه و با ری‌استارت
#     سرور هم خودکار بالا بیاد (بدون نیاز به نگه داشتن ترمینال باز)
# =============================================================================
set -euo pipefail

APP_DIR="/opt/saybuuy-bale-bot"
SERVICE_NAME="saybuuy-bale-bot"
RUN_USER="${SUDO_USER:-$USER}"

echo "== نصب پیش‌نیازها =="
if ! command -v python3 &>/dev/null; then
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip
elif ! python3 -m venv --help &>/dev/null; then
  apt-get update -y
  apt-get install -y python3-venv
fi

echo "== ساخت/آپدیت پوشه‌ی پروژه در $APP_DIR =="
mkdir -p "$APP_DIR"

cat > "$APP_DIR/bot.py" <<'BOT_PY_EOF'
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
import sys
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

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PID_FILE = os.path.join(BASE_DIR, ".bot.pid")
OFFSET_FILE = os.path.join(BASE_DIR, ".bot_offset")

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
    elif command == "/about":
        send_message(chat_id, msg.ABOUT_INFO, main_keyboard())
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
# جلوگیری از اجرای هم‌زمان دو نسخه از بات
# ---------------------------------------------------------------------------
# اگه دو تا پردازش بات هم‌زمان روی یک توکن اجرا بشن، هر دو سعی می‌کنن به
# آپدیت‌های قدیمی (که قبلاً توسط پردازش دیگه جواب داده شدن) پاسخ بدن و
# مدام خطای «query is too old» می‌گیرن. برای جلوگیری از این حالت، یک
# فایل قفل (PID) نگه می‌داریم.

def acquire_single_instance_lock():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)  # فقط چک می‌کنه که پردازش زنده است یا نه
            log.error(
                "به نظر می‌رسه یک نسخه‌ی دیگه از بات (PID=%s) از قبل در حال اجراست. "
                "این پردازش رو متوقف می‌کنم تا با اون تداخل نکنه.",
                old_pid,
            )
            sys.exit(1)
        except (ProcessLookupError, ValueError, PermissionError, OSError):
            # پردازش قبلی دیگه زنده نیست؛ قفل قدیمی و بی‌اعتباره
            pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def release_single_instance_lock():
    try:
        os.remove(PID_FILE)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# مدیریت offset (برای اینکه بعد از هر ری‌استارت، آپدیت‌های قدیمی/منقضی از
# صف بله دوباره پردازش نشن و باعث اسپم خطای «query is too old» نشن)
# ---------------------------------------------------------------------------

def load_saved_offset():
    if os.path.exists(OFFSET_FILE):
        try:
            with open(OFFSET_FILE) as f:
                return int(f.read().strip())
        except (ValueError, OSError):
            return None
    return None


def save_offset(offset):
    try:
        with open(OFFSET_FILE, "w") as f:
            f.write(str(offset))
    except OSError:
        pass


def flush_stale_updates():
    """در اولین اجرا (وقتی هنوز offset ذخیره‌شده‌ای نداریم)، هر آپدیت قدیمی
    که در صف بله مونده رو بدون پردازش رد می‌کنیم؛ فقط offset رو جلو می‌بریم.
    این کار از پاسخ دادن به دکمه‌های قدیمی/منقضی (و در نتیجه خطای پشت‌سرهم
    «query is too old») جلوگیری می‌کنه."""
    data = api_call("getUpdates", {"offset": 0, "timeout": 0}, timeout=REQUEST_TIMEOUT)
    if not data or not data.get("ok"):
        return 0
    results = data.get("result", [])
    if not results:
        return 0
    new_offset = results[-1]["update_id"] + 1
    log.info("تعداد %d آپدیت قدیمی/باقی‌مانده از قبل نادیده گرفته شد.", len(results))
    return new_offset


# ---------------------------------------------------------------------------
# حلقه‌ی اصلی Long Polling
# ---------------------------------------------------------------------------

def run():
    acquire_single_instance_lock()
    try:
        log.info("بات در حال اجراست (Long Polling)... برای توقف Ctrl+C بزن.")

        offset = load_saved_offset()
        if offset is None:
            offset = flush_stale_updates()
            save_offset(offset)

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
                    save_offset(offset)
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
    finally:
        release_single_instance_lock()


if __name__ == "__main__":
    run()

BOT_PY_EOF

cat > "$APP_DIR/messages.py" <<'MESSAGES_PY_EOF'
# -*- coding: utf-8 -*-
"""
تمام متن‌های تبلیغاتی و بازاریابی بات در همین فایل جمع شده تا به‌راحتی
بدون نیاز به تغییر منطق برنامه، ویرایش و A/B تست بشن.

نکته‌ی مهم درباره‌ی فرمت متن:
برخلاف تلگرام، بازوی بله پارامتر parse_mode نداره و متن هر پیام همیشه با
فرمت اختصاصیِ خودِ بله پردازش می‌شه که با Markdown استاندارد فرق داره:
  - پررنگ: بین دو ستاره، با یک فاصله قبل از ستاره‌ی اول و بعد از ستاره‌ی دوم
    مثال درست:  متن عادی  *متن پررنگ*  متن عادی
  - ایتالیک: بین دو زیرخط (_)، با همون قاعده‌ی فاصله
  - لینک: [متن](آدرس)
  - بله خط‌خورده (strikethrough) پشتیبانی نمی‌کنه؛ برای همین به‌جای
    خط‌خوردن قیمت قبلی، از برچسب‌های متنی («قیمت قبلی» / «قیمت اکنون»)
    استفاده شده.

این متن‌ها روی صفحه‌ی لندینگ w1-ultra-mini استخراج شده (نام محصول، قیمت،
تخفیف، عکس‌ها). جاهایی که اطلاعات دقیقی از خود لندینگ در دسترس نبود (مثل
مشخصات فنی دقیق یا شرایط گارانتی)، از ادعای مشخص و قابل‌اثبات پرهیز شده تا
تبلیغ گمراه‌کننده نباشه. پیشنهاد می‌شه این بخش‌ها رو با اطلاعات دقیق و
واقعی خودتون تکمیل کنید.
"""

LANDING_URL = "https://shop.saybuuy.com/offers/w1-ultra-mini"
LICENSE_TRACKING_CODE = "I165822"

PRODUCT_NAME = "ساعت هوشمند W1 Ultra Mini"
PRICE_DISCOUNTED = "۳,۴۹۷,۰۰۰"
PRICE_ORIGINAL = "۶,۰۰۰,۰۰۰"
DISCOUNT_PERCENT = "۴۲٪"  # (۶,۰۰۰,۰۰۰ - ۳,۴۹۷,۰۰۰) / ۶,۰۰۰,۰۰۰ ≈ ۴۲٪

# ---------------------------------------------------------------------------
# پیام خوش‌آمد / استارت
# ---------------------------------------------------------------------------
WELCOME = f"""⌚️ سلام! خوش اومدی به Saybuuy 🎉

فقط چند لحظه وقت بذار، شاید همین امروز جذاب‌ترین هدیه‌ی این فصل رو با تخفیف ویژه بگیری 👇

🎁 *{PRODUCT_NAME}*
یه ساعت هوشمند شیک و اسپرت، انتخاب محبوب نوجوون‌ها و جوون‌های امروزی؛ عالی برای هدیه دادن یا هدیه گرفتن 😍

✅ ده‌ها صفحه‌نمایش (واچ‌فیس) متنوع و رنگی
✅ طراحی مینیمال، اسپرت و امروزی
✅ مجهز به امکانات هوشمند روزمره
✅ رنگ‌بندی متنوع، از جمله رنگ قرمز محبوب 🔴

💰 قیمت ویژه‌ی آخر فصل:
قیمت قبلی: {PRICE_ORIGINAL} تومان
قیمت اکنون: *{PRICE_DISCOUNTED}* تومان ( *{DISCOUNT_PERCENT}* تخفیف)

⏳ این پیشنهاد آخرین آفر پایان فصل هست و موجودی محدوده؛ تا تموم نشده، فرصتش رو از دست نده!

👇 با یک کلیک، مستقیم برو صفحه‌ی خرید و ثبت سفارش کن:"""

# دکمه‌های زیر پیام خوش‌آمد
BTN_BUY = f"🛒 خرید فوری با {DISCOUNT_PERCENT} تخفیف"
BTN_FEATURES = "✨ ویژگی‌های ساعت"
BTN_WHY = "❓ چرا همین الان بخرم؟"
BTN_PRICE = "💰 قیمت و تخفیف"
BTN_BACK = "🔙 بازگشت"

# ---------------------------------------------------------------------------
# ویژگی‌ها
# ---------------------------------------------------------------------------
FEATURES = f"""✨ ویژگی‌های *{PRODUCT_NAME}*

⌚️ صفحه‌نمایش رنگی با ده‌ها طرح و واچ‌فیس قابل انتخاب
🎨 طراحی مینیمال و اسپرت، مناسب استفاده روزانه
🎁 گزینه‌ی ایده‌آل برای هدیه به نوجوان‌ها و جوون‌ها
🔴 در رنگ‌بندی‌های متنوع، از جمله قرمز پرطرفدار

برای مشاهده‌ی کامل مشخصات، گالری تصاویر و جزئیات بیشتر، حتماً یه سر به صفحه‌ی محصول بزن 👇"""

# ---------------------------------------------------------------------------
# چرا همین الان بخرم (فوریت / کمیابی)
# ---------------------------------------------------------------------------
WHY_NOW = f"""⏳ چرا الان بهترین زمان خریده؟

🔥 این تخفیف *{DISCOUNT_PERCENT}* آخرین آفر پایان فصله و همیشگی نیست
📉 قیمت از {PRICE_ORIGINAL} تومان رسیده به *{PRICE_DISCOUNTED}* تومان
🎯 موجودی این آفر محدوده و با تموم شدنش، قیمت به حالت عادی برمی‌گرده
🎁 یه فرصت عالی برای هدیه دادن زودتر از موعد

اگه داری بهش فکر می‌کنی، بهتره زودتر تصمیم بگیری تا از دستش ندی 👇"""

# ---------------------------------------------------------------------------
# قیمت
# ---------------------------------------------------------------------------
PRICE_INFO = f"""💰 قیمت *{PRODUCT_NAME}*

قیمت قبلی: {PRICE_ORIGINAL} تومان
قیمت با تخفیف ویژه: *{PRICE_DISCOUNTED}* تومان
میزان تخفیف: *{DISCOUNT_PERCENT}*

این قیمت فقط تا پایان مهلت آفر معتبره. برای ثبت سفارش با همین قیمت، رو دکمه‌ی زیر بزن 👇"""

# ---------------------------------------------------------------------------
# پیامی که به هر پیام متنی دیگه‌ای (غیر از دستورات) داده می‌شه
# ---------------------------------------------------------------------------
FALLBACK = f"""ممنون از پیامت! 🙏

برای دیدن جزئیات و خرید *{PRODUCT_NAME}* با *{DISCOUNT_PERCENT}* تخفیف ویژه‌ی پایان فصل، از دکمه‌های زیر استفاده کن 👇"""

# پیامی که بعد از کلیک روی دکمه‌ی خرید (به‌عنوان یادآوری/تشویق نهایی) نمایش داده می‌شه
BUY_FOLLOWUP = f"""🛍 عالیه! صفحه‌ی خرید *{PRODUCT_NAME}* برات باز شد.

⏳ یادت باشه این قیمت ( {PRICE_DISCOUNTED} تومان ) فقط تا پایان آفر معتبره. ثبت سفارشت رو کامل کن تا از تخفیف جا نمونی 🎉"""

COMMAND_HELP = f"""دستورات قابل استفاده:
/start – نمایش پیشنهاد ویژه و شروع دوباره
/price – مشاهده‌ی قیمت و تخفیف
/buy – دریافت لینک خرید مستقیم
/about – اطلاعات فروشگاه و کد پیگیری مجوز

🔖 کد پیگیری مجوز: {LICENSE_TRACKING_CODE}"""

# پیام دستور /about
ABOUT_INFO = f"""🏪 Saybuuy — چند قدم جلوتر

فروش {PRODUCT_NAME} و محصولات دیگه از طریق:
{LANDING_URL}

🔖 کد پیگیری مجوز: {LICENSE_TRACKING_CODE}"""

MESSAGES_PY_EOF

cat > "$APP_DIR/requirements.txt" <<'REQ_EOF'
requests>=2.31.0
python-dotenv>=1.0.0

REQ_EOF

# اگه از قبل .env با توکن معتبر داریم، دوباره چیزی نمی‌پرسیم (برای آپدیت‌های بعدی)
if [ -f "$APP_DIR/.env" ] && grep -q '^BALE_BOT_TOKEN=' "$APP_DIR/.env" 2>/dev/null; then
  echo "== توکن از قبل موجوده؛ استفاده از همون =="
elif [ -n "${BALE_BOT_TOKEN:-}" ]; then
  echo "BALE_BOT_TOKEN=$BALE_BOT_TOKEN" > "$APP_DIR/.env"
else
  read -rp "توکن بات بله رو وارد کن (فرمت 123456:abcDEF...): " BALE_BOT_TOKEN
  echo "BALE_BOT_TOKEN=$BALE_BOT_TOKEN" > "$APP_DIR/.env"
fi

echo "== ساخت virtualenv و نصب پکیج‌ها =="
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"

chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR"

echo "== ساخت/آپدیت systemd service =="
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE_EOF
[Unit]
Description=Saybuuy Bale Bot (W1 Ultra Mini)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

echo ""
echo "✅ بات نصب/آپدیت و اجرا شد و به‌صورت ۲۴ساعته (با ری‌استارت خودکار) در حال کاره."
echo ""
echo "دستورات مفید:"
echo "  وضعیت:      systemctl status $SERVICE_NAME"
echo "  لاگ زنده:    journalctl -u $SERVICE_NAME -f"
echo "  توقف:       systemctl stop $SERVICE_NAME"
echo "  ری‌استارت:   systemctl restart $SERVICE_NAME"
echo "  ویرایش متن‌ها: nano $APP_DIR/messages.py   (بعدش: systemctl restart $SERVICE_NAME)"
