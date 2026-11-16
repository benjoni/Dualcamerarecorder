<?php
// Stripe webhook (event invoice.paid): every paid invoice of a subscription – the first one and each renewal –
// gets a licence for the Mac in the subscription's metadata, valid until the end of the paid period plus a few
// days (time for a renewal that is retried). The licence is e-mailed and kept for the success page.

declare(strict_types=1);
require __DIR__ . '/lib.php';

const GRACE_DAYS = 3;

$payload = (string)file_get_contents('php://input');
if (!webhook_signature_ok($payload, $_SERVER['HTTP_STRIPE_SIGNATURE'] ?? '', STRIPE_WEBHOOK_SECRET)) {
    http_response_code(400);
    exit('bad signature');
}
$event = json_decode($payload, true);
if (!is_array($event) || ($event['type'] ?? '') !== 'invoice.paid') {
    exit('ignored');
}
$invoice = $event['data']['object'];
$invoiceID = preg_replace('/[^A-Za-z0-9_]/', '', (string)($invoice['id'] ?? ''));
$subscriptionID = $invoice['subscription']
    ?? ($invoice['parent']['subscription_details']['subscription'] ?? null);
if ($invoiceID === '' || !is_string($subscriptionID) || $subscriptionID === '') {
    exit('no subscription');
}
// Stripe sends an event again when the answer was late – one licence per invoice.
$done = data_dir('invoices') . "/$invoiceID";
if (is_file($done)) { exit('already done'); }

try {
    $subscription = stripe('GET', '/v1/subscriptions/' . rawurlencode($subscriptionID));
    $meta = $subscription['metadata'] ?? [];
    $mac = normalized_mac((string)($meta['mac'] ?? ''));
    $name = trim((string)($meta['name'] ?? ''));
    $plan = (string)($meta['plan'] ?? '');
    if ($mac === null || $name === '') { throw new RuntimeException("subscription $subscriptionID has no Mac ID / name"); }

    // End of the paid period: from the invoice lines (or the subscription).
    $periodEnd = 0;
    foreach ($invoice['lines']['data'] ?? [] as $line) {
        $periodEnd = max($periodEnd, (int)($line['period']['end'] ?? 0));
    }
    if ($periodEnd <= time()) {
        $periodEnd = (int)($subscription['current_period_end'] ?? $subscription['items']['data'][0]['current_period_end'] ?? 0);
    }
    if ($periodEnd <= time()) { throw new RuntimeException("invoice $invoiceID has no period end"); }
    $expires = $periodEnd + GRACE_DAYS * 86400;

    $licence = make_licence($name, $mac, $expires);
    file_put_contents(data_dir('licences') . "/$invoiceID.dcrlicense", $licence);
    file_put_contents(data_dir('subscriptions') . '/' . preg_replace('/[^A-Za-z0-9_]/', '', $subscriptionID) . '.json',
        json_encode(['licence' => $licence, 'file' => licence_file_name($name), 'name' => $name, 'mac' => $mac,
                     'expires' => $expires, 'invoice' => $invoiceID, 'plan' => $plan], JSON_UNESCAPED_UNICODE));

    $email = (string)($invoice['customer_email'] ?? '');
    $sent = $email !== '' && mail_licence($email, $name, $licence, $expires,
                                          $plan === 'yearly' ? 'yearly' : ($plan === 'monthly' ? 'monthly' : $plan));
    touch($done);
    log_line("licence $invoiceID $subscriptionID " . formatted_mac($mac) . " \"$name\" until " . gmdate('Y-m-d', $expires)
             . ($sent ? " mailed to $email" : ' NOT MAILED'));
    echo 'ok';
} catch (Throwable $e) {
    log_line('webhook failed: ' . $e->getMessage());
    http_response_code(500);   // Stripe tries again later
    echo 'error';
}
