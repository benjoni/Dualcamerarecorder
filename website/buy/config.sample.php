<?php
// Copy to config.php ON THE SERVER ONLY (config.php is not in git) and fill in.
// Stripe values: prices from Product catalog → DualCamRecorder, webhook secret from Developers → Webhooks.

const SITE_URL = 'https://dualrecorder.benjoni.com';

// Stripe: Developers → API keys (sk_test_… while testing, sk_live_… for real sales).
const STRIPE_SECRET_KEY = 'sk_test_...';
// Stripe: the webhook endpoint for /buy/webhook.php → Signing secret.
const STRIPE_WEBHOOK_SECRET = 'whsec_...';
// Prices of the product DualCamRecorder (Product catalog) – 200 € / month and 2000 € / year, without VAT.
const PRICE_MONTHLY = 'price_1UZZi0RsVgpe8EGOr5I4JZ1E';
const PRICE_YEARLY = 'price_1UZZs9RsVgpe8EGObIJ7X59P';
// VAT added by Stripe Tax (Settings → Tax: origin address and registrations must be filled in).
const AUTOMATIC_TAX = true;
// Black Friday: coupon "Blackfriday" (50 % once = 1000 € off the first year), applied to the yearly plan until the end.
const BLACKFRIDAY_COUPON = 'qqMvJEsi';
const BLACKFRIDAY_END = 1796079599;   // 30 Nov 2026 23:59:59 Bratislava

// The licence signing key: the one line of
// ~/Library/Application Support/DualCamRecorder License Key/private.key
// Whoever has it can make licences – keep this file private.
const LICENSE_PRIVATE_KEY = '...';

// E-mail with the licence.
const MAIL_FROM = 'DualCamRecorder <licence@benjoni.com>';
const MAIL_COPY_TO = '';          // your address for a copy of every licence e-mail (optional)
const SUPPORT_EMAIL = 'info@benjoni.com';

// Issued licences and the shop log (names, Mac IDs, e-mails). Best outside the website folder, e.g.
// dirname(__DIR__, 2) . '/dualrecorder-shop-data'; otherwise a folder name nobody can guess.
const DATA_DIR = __DIR__ . '/data';

// Stripe: Settings → Billing → Customer portal → link (customers cancel / change the card there). Optional.
const CUSTOMER_PORTAL_URL = '';
