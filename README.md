# getPHP - Local PHP Stack. One Command. Done.

Launch your local PHP web stack with a single command. Enjoy a full development environment without the bloat of a desktop application. Please visit [getPHP.org](https://getphp.org) to subscribe for updates.

## Apple Silicon Mac
Copy & paste this into your terminal:
```shell
/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/getphporg/getphp/HEAD/getphp.sh)"
```
## Ubuntu, Debian, Mint
Copy & paste this into your terminal:
```shell
if ! command -v curl &> /dev/null; then sudo apt install -y curl; fi && source <(curl -fsSL https://raw.githubusercontent.com/getphporg/getphp/HEAD/getphp.sh)
```
## Windows 11
Currently under development.

## Zero Footprint
The getPHP script runs entirely in-memory and never installs itself on your machine. Only the PHP stack is added if you choose to install it. To manage services, update, or uninstall the stack, simply re-run the command in your terminal at any time.

## What does the getPHP script do?
It lets you install and manage (update, restart, delete) your local PHP web stack.

## What exactly happens during installation?
The getPHP script installs and configures everything you need to start PHP web development on your machine:
- installs Homebrew
- installs Apache
- installs MySQL
- installs PHP
- installs phpMyAdmin
- enables port 80 in Apache
- creates a localhost directory for the user
- configures DocumentRoot
- sets access_log and error_log locations
- loads php_module
- enables PHP in Apache
- configures DirectoryIndex
- loads rewrite_module
- sets AllowOverride All
- enables phpMyAdmin in Apache
- sets blowfish_secret
- enables passwordless login in phpMyAdmin
- creates a phpinfo.php file to test PHP
- starts the httpd service
- starts the mysql service
- starts the php service

## How does getPHP work?
It is a shell script that runs directly from GitHub and leaves no footprint on your system. Your PHP stack is only installed once you explicitly choose to do so.

## Is the getPHP script free?
Yes, the getPHP script is 100% free and open source.

## Support & Contributions
If you enjoy using getPHP, please give it a star on GitHub to help others find it.

If you run into any errors or bugs, please let me know by opening an [issue](https://github.com/getphporg/getphp/issues) or sending a [pull request](https://github.com/getphporg/getphp/pulls).

You can also directly contact me through the [Support Page](https://getphp.org/support.php) at [getPHP.org](https://getphp.org).

---

> **Disclaimer:** getPHP is an independent open-source tool and is not affiliated with, sponsored by, or endorsed by the PHP Group or the PHP Foundation.
