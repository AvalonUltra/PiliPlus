$ErrorActionPreference = "Stop"

$Path = "lib/plugin/pl_player/view/view.dart"
$text = Get-Content -Path $Path -Raw

$old = @'
        if (_pauseDueToPauseUponEnteringBackgroundMode) {
          _pauseDueToPauseUponEnteringBackgroundMode = false;
          player?.play();
        }
'@

$new = @'
        if (_pauseDueToPauseUponEnteringBackgroundMode) {
          _pauseDueToPauseUponEnteringBackgroundMode = false;
          plPlayerController.play();
        }
'@

if ($text.Contains($new)) {
    Write-Host "iOS HDR foreground resume patch already applied"
    return
}

if (!$text.Contains($old)) {
    throw "Unable to apply iOS HDR foreground resume patch: expected block not found in $Path"
}

Set-Content -Path $Path -Value $text.Replace($old, $new) -NoNewline -Encoding utf8
Write-Host "iOS HDR foreground resume patch applied"
