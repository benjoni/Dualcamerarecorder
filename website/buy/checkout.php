<?php
// Buy form → Stripe Checkout (subscription). The Mac ID and the licence name go with the subscription as
// metadata; webhook.php makes the licence from them after every paid invoice.

declare(strict_types=1);
require __DIR__ . '/lib.php';

function back(string $problem): never {
    header('Location: ' . SITE_URL . '/?buy_error=' . rawurlencode($problem) . '#buy', true, 303);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') { back('Please use the form.'); }

$plan = $_POST['plan'] ?? '';
$price = ['monthly' => PRICE_MONTHLY, 'yearly' => PRICE_YEARLY][$plan] ?? null;
if ($price === null) { back('Choose monthly or yearly.'); }

$mac = normalized_mac((string)($_POST['mac'] ?? ''));
if ($mac === null) { back('The Mac ID is not complete – copy it from DualCamRecorder → License… (e.g. ABCD-EFGH-JKMN-PQRS).'); }

$name = trim(preg_replace('/\s+/', ' ', (string)($_POST['name'] ?? '')));
if ($name === '' || mb_strlen($name) > 80) { back('Fill in the name the licence is for (person or company).'); }

// Black Friday: the yearly price on the website already has the discount (2000 € → 1000 € the first year) –
// the coupon is applied here. No codes can be typed in: the coupon (50 %) would also take 100 € off a month.
$discount = [];
if ($plan === 'yearly' && defined('BLACKFRIDAY_COUPON') && defined('BLACKFRIDAY_END') && BLACKFRIDAY_COUPON !== '' && time() < BLACKFRIDAY_END) {
    $discount = ['discounts' => [['coupon' => BLACKFRIDAY_COUPON]]];
}

try {
    $session = stripe('POST', '/v1/checkout/sessions', $discount + [
        'mode' => 'subscription',
        'line_items' => [['price' => $price, 'quantity' => 1]],
        // Stripe Tax adds VAT on top (prices are without VAT); needs the origin address and registrations in Stripe.
        'automatic_tax' => ['enabled' => (!defined('AUTOMATIC_TAX') || AUTOMATIC_TAX) ? 'true' : 'false'],
        'tax_id_collection' => ['enabled' => 'true'],
        'billing_address_collection' => 'required',
        'metadata' => ['mac' => $mac, 'name' => $name, 'plan' => $plan],
        'subscription_data' => ['metadata' => ['mac' => $mac, 'name' => $name, 'plan' => $plan]],
        'success_url' => SITE_URL . '/buy/success.php?session_id={CHECKOUT_SESSION_ID}',
        'cancel_url' => SITE_URL . '/#buy',
        'locale' => 'auto',
    ]);
} catch (Throwable $e) {
    log_line('checkout failed: ' . $e->getMessage());
    back('The payment page could not be opened. Please try again in a moment.');
}

log_line("checkout {$session['id']} $plan " . formatted_mac($mac) . " \"$name\"");
count_event('checkout');
header('Location: ' . $session['url'], true, 303);
