# phpup bootstrap.
#
# Why this file exists: phpup.ps1 keeps a UTF-8 BOM so that Windows PowerShell
# 5.1 decodes its non-ASCII characters correctly. When that same file is piped
# into `iex`, the BOM travels inside the string, attaches itself to the first
# `#` comment and turns it into an unrecognised command, which breaks the
# param block below it. This launcher is ASCII and BOM-free, so a plain
# `irm <this file> | iex` works, and it hands the real script over the same way
# after dropping the BOM.
#
# Keep this file pure ASCII. Do not add a BOM.

$url = 'https://raw.githubusercontent.com/DaFa66/phpup/HEAD/phpup.ps1'
$src = Invoke-RestMethod -Uri $url
Invoke-Expression ($src.TrimStart([char]0xFEFF))
