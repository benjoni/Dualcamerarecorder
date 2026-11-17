<?php
// Free trial: the form in the "Try it" section of the website → a licence for one Mac, valid TRIAL_DAYS days,
// sent by e-mail (so the address is real). One trial per Mac and per e-mail address; a few per IP and day.
// GET ?sent=1 shows the "check your e-mail" page.

declare(strict_types=1);
require __DIR__ . '/lib.php';

const TRIAL_DAYS = 14;
const TRIALS_PER_IP_AND_DAY = 3;

function back(string $problem): never {
    header('Location: ' . SITE_URL . '/?trial_error=' . rawurlencode($problem) . '#try', true, 303);
    exit;
}

/** Marker files of earlier trials (data/trials/, not reachable from the web). */
function trial_marker(string $kind, string $value): string {
    return data_dir('trials') . "/$kind-" . substr(hash('sha256', $value), 0, 32);
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    // Bots fill in every field, people do not see this one.
    if (trim((string)($_POST['website'] ?? '')) !== '') { header('Location: trial.php?sent=1', true, 303); exit; }

    $mac = normalized_mac((string)($_POST['mac'] ?? ''));
    if ($mac === null) { back('The Mac ID is not complete – copy it from DualCamRecorder → License… (e.g. ABCD-EFGH-JKMN-PQRS).'); }
    $name = trim(preg_replace('/\s+/', ' ', (string)($_POST['name'] ?? '')));
    if ($name === '' || mb_strlen($name) > 80) { back('Fill in your name or company.'); }
    $email = trim((string)($_POST['email'] ?? ''));
    if (strlen($email) > 120 || filter_var($email, FILTER_VALIDATE_EMAIL) === false || preg_match('/[\r\n]/', $email)) {
        back('Fill in a valid e-mail address – the licence is sent there.');
    }
    $support = defined('SUPPORT_EMAIL') ? SUPPORT_EMAIL : '';

    // One trial per Mac and per e-mail; a few per IP and day.
    $macMarker = trial_marker('mac', $mac);
    $mailMarker = trial_marker('mail', strtolower($email));
    if (is_file($macMarker) || is_file($mailMarker)) {
        log_line('trial refused (repeat) ' . formatted_mac($mac));
        back("This Mac or e-mail address already had a trial. For a longer test write to $support.");
    }
    $ip = trim(explode(',', (string)($_SERVER['HTTP_X_FORWARDED_FOR'] ?? $_SERVER['REMOTE_ADDR'] ?? ''))[0]);
    $ipFile = trial_marker('ip-' . gmdate('Ymd'), $ip);
    $ipCount = (int)@file_get_contents($ipFile);
    if ($ipCount >= TRIALS_PER_IP_AND_DAY) { back("Too many trials from this network today. Please write to $support."); }
    foreach (glob(data_dir('trials') . '/ip-*') ?: [] as $old) {   // yesterday's IP counts are not needed
        if (!str_starts_with(basename($old), 'ip-' . gmdate('Ymd') . '-')) { @unlink($old); }
    }

    $expires = time() + TRIAL_DAYS * 86400;
    try {
        $licence = make_licence("$name (trial)", $mac, $expires);
    } catch (Throwable $e) {
        log_line('trial licence failed: ' . $e->getMessage());
        back("The trial licence could not be made right now. Please write to $support.");
    }
    if (!mail_trial_licence($email, $name, $licence, $expires)) {
        log_line('trial e-mail failed ' . formatted_mac($mac));
        back("The e-mail could not be sent. Please check the address or write to $support.");
    }
    file_put_contents($ipFile, (string)($ipCount + 1), LOCK_EX);
    $record = json_encode(['date' => gmdate('c'), 'mac' => $mac, 'name' => $name, 'email' => $email,
                           'expires' => gmdate('c', $expires)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    file_put_contents($macMarker, $record, LOCK_EX);
    file_put_contents($mailMarker, $record, LOCK_EX);
    $csv = fopen(data_dir() . '/trials.csv', 'a');
    if ($csv) { fputcsv($csv, [gmdate('Y-m-d H:i:s'), formatted_mac($mac), $name, $email, gmdate('Y-m-d', $expires)], ',', '"', ''); fclose($csv); }
    log_line('trial ' . formatted_mac($mac) . " \"$name\" until " . gmdate('Y-m-d', $expires));
    count_event('trial');
    header('Location: trial.php?sent=1', true, 303);
    exit;
}
if (!isset($_GET['sent'])) { header('Location: ' . SITE_URL . '/#try', true, 303); exit; }
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>DualCamRecorder – trial</title>
<link rel="stylesheet" href="shop.css">
</head>
<body>
<main class="box">
  <a class="brand" href="<?= h(SITE_URL) ?>/"><img src="../media/icon.png" alt="">DualCamRecorder</a>
  <span class="kicker">Free trial · <?= TRIAL_DAYS ?> days</span>
  <h1>Check your e-mail</h1>
  <p>Your trial licence is on its way. It is made for your Mac and records for <?= TRIAL_DAYS ?> days.</p>
  <ol class="steps">
    <li>Install DualCamRecorder – <a href="<?= h(download_url()) ?>" onclick="navigator.sendBeacon('../stats/hit.php?e=download')">download the app</a> (macOS 13 or later).</li>
    <li>Open <b>DualCamRecorder → License…</b> and drop the licence file from the e-mail on the window, or press <b>Import License…</b>.</li>
    <li>Recording is on. After the trial the app still plays, edits and exports – <a href="<?= h(SITE_URL) ?>/#buy">buy a licence</a> to keep recording.</li>
  </ol>
  <p class="muted">No e-mail after a few minutes? Look in the spam folder, or write to <a href="mailto:<?= h(SUPPORT_EMAIL) ?>"><?= h(SUPPORT_EMAIL) ?></a>.</p>
</main>
</body>
</html>
