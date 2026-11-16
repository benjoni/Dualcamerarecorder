<?php
// Visit statistics for Benjoni – behind a password (stats/password.php on the server, not in git).
// Last 30 days: views, visitors, where they came from, Buy clicks → payments → purchases.

declare(strict_types=1);
require __DIR__ . '/lib.php';

$passwordFile = __DIR__ . '/password.php';
if (!is_file($passwordFile)) { http_response_code(503); exit('Statistics are not set up (stats/password.php is missing).'); }
require $passwordFile;   // const STATS_PASSWORD_HASH = '$2y$…';

session_set_cookie_params(['lifetime' => 0, 'path' => '/stats/', 'secure' => true, 'httponly' => true, 'samesite' => 'Strict']);
session_name('dcrstats');
session_start();
if (isset($_GET['logout'])) { $_SESSION = []; session_destroy(); header('Location: ./'); exit; }
$problem = '';
if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    usleep(400000);   // slows down guessing
    if (password_verify((string)($_POST['password'] ?? ''), STATS_PASSWORD_HASH)) {
        session_regenerate_id(true);
        $_SESSION['ok'] = true;
        header('Location: ./');
        exit;
    }
    $problem = 'Wrong password.';
}
function h(string $t): string { return htmlspecialchars($t, ENT_QUOTES, 'UTF-8'); }
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>DualCamRecorder – visits</title>
<style>
:root { --bg:#0c0c0d; --panel:#17171a; --line:#2a2a2e; --ink:#f2f0ea; --muted:#a3a09a; --tally:#e5342a; --amber:#f0a234; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 "Helvetica Neue", Arial, sans-serif; }
main { width: min(1100px, 100% - 32px); margin: 40px auto 64px; display: grid; gap: 28px; }
h1 { margin: 0; font-size: 34px; } h2 { margin: 0 0 12px; font-size: 20px; }
.muted { color: var(--muted); } a { color: inherit; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.tile { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px; }
.tile b { display: block; font-size: 30px; font-variant-numeric: tabular-nums; }
.tile span { color: var(--muted); font-size: 13px; }
.box { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 18px; overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; font-size: 14px; }
th, td { text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
th:first-child, td:first-child { text-align: left; }
th { color: var(--muted); font-weight: 600; }
.bar { display: inline-block; height: 8px; border-radius: 4px; background: var(--tally); vertical-align: middle; margin-left: 8px; }
.two { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; } @media (max-width: 760px) { .two { grid-template-columns: 1fr; } }
form.login { display: grid; gap: 12px; max-width: 320px; }
input { font: inherit; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--line); background: #202023; color: var(--ink); }
button { font: inherit; font-weight: 700; padding: 10px 14px; border-radius: 8px; border: 0; background: var(--tally); color: #fff; cursor: pointer; }
.err { color: #ffb3ad; }
</style>
</head>
<body>
<main>
<?php if (empty($_SESSION['ok'])): ?>
  <h1>Visits</h1>
  <form class="login" method="post">
    <input type="password" name="password" placeholder="Password" autofocus autocomplete="current-password">
    <button type="submit">Show statistics</button>
    <?php if ($problem): ?><span class="err"><?= h($problem) ?></span><?php endif; ?>
  </form>
<?php else:
    $days = stats_days(30);
    $sum = fn(string $key) => array_sum(array_map(fn($d) => $key === 'visitors' ? count($d['visitors']) : $d[$key], $days));
    $event = fn(array $d, string $e) => (int)($d['events'][$e] ?? 0);
    $eventSum = fn(string $e) => array_sum(array_map(fn($d) => $event($d, $e), $days));
    $last7 = array_slice($days, 0, 7, true);
    $refs = []; $pages = [];
    foreach ($days as $d) {
        foreach ($d['refs'] as $r => $n) { $refs[$r] = ($refs[$r] ?? 0) + $n; }
        foreach ($d['pages'] as $p => $n) { $pages[$p] = ($pages[$p] ?? 0) + $n; }
    }
    arsort($refs); arsort($pages);
    $maxViews = max(1, ...array_values(array_map(fn($d) => $d['views'], $days)));
?>
  <div style="display:flex;justify-content:space-between;align-items:baseline;gap:16px;flex-wrap:wrap">
    <h1>Visits · last 30 days</h1>
    <span class="muted">dualrecorder.benjoni.com · days in UTC · <a href="?logout">log out</a></span>
  </div>
  <div class="tiles">
    <div class="tile"><b><?= $sum('visitors') ?></b><span>Visitors (30 days)</span></div>
    <div class="tile"><b><?= array_sum(array_map(fn($d) => count($d['visitors']), $last7)) ?></b><span>Visitors (7 days)</span></div>
    <div class="tile"><b><?= $sum('views') ?></b><span>Page views (30 days)</span></div>
    <div class="tile"><b><?= $eventSum('buy') ?></b><span>Buy / Pricing clicks</span></div>
    <div class="tile"><b><?= $eventSum('checkout') ?></b><span>Payment page opened</span></div>
    <div class="tile"><b><?= $eventSum('purchase') ?></b><span>Paid</span></div>
  </div>
  <div class="box">
    <h2>By day</h2>
    <table>
      <tr><th>Day</th><th>Visitors</th><th>Views</th><?php foreach (STATS_EVENTS as $label): ?><th><?= h($label) ?></th><?php endforeach; ?></tr>
      <?php foreach ($days as $day => $d): ?>
      <tr>
        <td><?= h(date('D j M', strtotime($day))) ?></td>
        <td><?= count($d['visitors']) ?></td>
        <td><?= $d['views'] ?><span class="bar" style="width:<?= (int)round(80 * $d['views'] / $maxViews) ?>px"></span></td>
        <?php foreach (array_keys(STATS_EVENTS) as $e): ?><td><?= $event($d, $e) ?: '·' ?></td><?php endforeach; ?>
      </tr>
      <?php endforeach; ?>
    </table>
  </div>
  <div class="two">
    <div class="box">
      <h2>Came from</h2>
      <table><tr><th>Site</th><th>Views</th></tr>
      <?php foreach (array_slice($refs, 0, 15, true) as $r => $n): ?><tr><td><?= h((string)$r) ?></td><td><?= $n ?></td></tr><?php endforeach; ?>
      <?php if (!$refs): ?><tr><td class="muted">No visits yet</td><td></td></tr><?php endif; ?>
      </table>
    </div>
    <div class="box">
      <h2>Pages</h2>
      <table><tr><th>Page</th><th>Views</th></tr>
      <?php foreach (array_slice($pages, 0, 15, true) as $p => $n): ?><tr><td><?= h((string)$p) ?></td><td><?= $n ?></td></tr><?php endforeach; ?>
      <?php if (!$pages): ?><tr><td class="muted">No visits yet</td><td></td></tr><?php endif; ?>
      </table>
    </div>
  </div>
  <p class="muted">Counted without cookies: a visitor is recognised only within one day (IP and browser, hashed with a salt that is deleted daily); no IP is stored. Bots and browsers that block scripts are not counted.</p>
<?php endif; ?>
</main>
</body>
</html>
