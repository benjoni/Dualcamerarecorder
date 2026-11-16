<?php
// After paying: the licence (made by webhook.php, usually within seconds) to download, and what to do with it.

declare(strict_types=1);
require __DIR__ . '/lib.php';

$sessionID = (string)($_GET['session_id'] ?? '');
$licence = null;
$problem = null;
$paid = false;
if (!preg_match('/^cs_[A-Za-z0-9_]+$/', $sessionID)) {
    $problem = 'This page needs the link from the payment.';
} else {
    try {
        $session = stripe('GET', '/v1/checkout/sessions/' . rawurlencode($sessionID));
        $paid = ($session['status'] ?? '') === 'complete';
        if (!$paid) {
            $problem = 'The payment is not finished.';
        } elseif (is_string($session['subscription'] ?? null)) {
            $licence = latest_licence($session['subscription']);
        }
    } catch (Throwable $e) {
        log_line('success page: ' . $e->getMessage());
        $problem = 'The payment could not be checked right now – the licence also comes by e-mail.';
    }
}
$waiting = $paid && $licence === null;
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DualCamRecorder – thank you</title>
<?php if ($waiting): ?><meta http-equiv="refresh" content="3"><?php endif; ?>
<link rel="stylesheet" href="shop.css">
</head>
<body>
<main class="box">
  <a class="brand" href="<?= h(SITE_URL) ?>/"><img src="../media/icon.png" alt="">DualCamRecorder</a>
<?php if ($problem !== null): ?>
  <h1>Almost there</h1>
  <p><?= h($problem) ?></p>
  <p class="muted">Questions: <a href="mailto:<?= h(SUPPORT_EMAIL) ?>"><?= h(SUPPORT_EMAIL) ?></a></p>
<?php elseif ($waiting): ?>
  <h1>Thank you!</h1>
  <p>The payment is done. Your licence is being made – this page refreshes by itself in a moment.</p>
<?php else: ?>
  <span class="kicker">Payment done</span>
  <h1>Thank you, <?= h($licence['name']) ?>!</h1>
  <p>Your licence for the Mac <b class="mono"><?= h(formatted_mac($licence['mac'])) ?></b> is valid until
     <b><?= h(gmdate('j F Y', (int)$licence['expires'])) ?></b>. It was also sent to your e-mail.</p>
  <a class="btn live" href="licence.php?session_id=<?= h(rawurlencode($sessionID)) ?>">Download the licence</a>
  <ol class="steps">
    <li>Install DualCamRecorder – <a href="<?= h(download_url()) ?>">download the app</a> (macOS 14 or later).</li>
    <li>Open <b>DualCamRecorder → License…</b> and drop the licence file on the window, or press <b>Import License…</b>.</li>
    <li>Recording is on. When the subscription renews, the new licence comes by e-mail – import it the same way.</li>
  </ol>
  <?php if (defined('CUSTOMER_PORTAL_URL') && CUSTOMER_PORTAL_URL !== ''): ?>
  <p class="muted">Invoices, card, cancel: <a href="<?= h(CUSTOMER_PORTAL_URL) ?>">manage your subscription</a>.</p>
  <?php endif; ?>
<?php endif; ?>
</main>
</body>
</html>
