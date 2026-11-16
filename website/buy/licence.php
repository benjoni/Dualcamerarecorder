<?php
// Download of the newest licence of a paid checkout (link on the success page).

declare(strict_types=1);
require __DIR__ . '/lib.php';

$sessionID = (string)($_GET['session_id'] ?? '');
if (!preg_match('/^cs_[A-Za-z0-9_]+$/', $sessionID)) { http_response_code(404); exit('Not found'); }
try {
    $session = stripe('GET', '/v1/checkout/sessions/' . rawurlencode($sessionID));
} catch (Throwable $e) {
    http_response_code(503);
    exit('The licence cannot be loaded right now – it was also sent by e-mail.');
}
$licence = ($session['status'] ?? '') === 'complete' && is_string($session['subscription'] ?? null)
    ? latest_licence($session['subscription']) : null;
if ($licence === null) { http_response_code(404); exit('The licence is not ready yet.'); }

$file = $licence['file'];
header('Content-Type: application/octet-stream');
header("Content-Disposition: attachment; filename=\"DualCamRecorder.dcrlicense\"; filename*=UTF-8''" . rawurlencode($file));
header('Cache-Control: no-store');
echo $licence['licence'];
