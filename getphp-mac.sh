#!/usr/bin/env sh

RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
UNDERLINE='\033[4m'
RESET='\033[0m'

HOMEBREW=0
APACHE=0
MYSQL=0
PHP=0
PHPMYADMIN=0
STACK=0

printf "\n"

printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
printf "║                                                                                ║\n"
printf "║     █████████  ██████████ ███████████ ███████████  █████   █████ ███████████   ║\n"
printf "║    ███░░░░░███░░███░░░░░█░█░░░███░░░█░░███░░░░░███░░███   ░░███ ░░███░░░░░███  ║\n"
printf "║   ███     ░░░  ░███  █ ░ ░   ░███  ░  ░███    ░███ ░███    ░███  ░███    ░███  ║\n"
printf "║  ░███          ░██████       ░███     ░██████████  ░███████████  ░██████████   ║\n"
printf "║  ░███    █████ ░███░░█       ░███     ░███░░░░░░   ░███░░░░░███  ░███░░░░░░    ║\n"
printf "║  ░░███  ░░███  ░███ ░   █    ░███     ░███         ░███    ░███  ░███          ║\n"
printf "║   ░░█████████  ██████████    █████    █████        █████   █████ █████         ║\n"
printf "║    ░░░░░░░░░  ░░░░░░░░░░    ░░░░░    ░░░░░        ░░░░░   ░░░░░ ░░░░░          ║\n"
printf "║    ${CYAN}www.getPHP.org - Local PHP Stack. One Command. Done.${RESET}                        ║\n"
printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"

printf "\n"

printf "Your PHP Stack:\n"
printf "~~~~~~~~~~~~~~~\n"
printf "Homebrew ${CYAN}----->${RESET} "
brew --version &> /dev/null && brew --version | awk '{print $2}' && HOMEBREW=1 || printf "${RED}not installed${RESET}\n"
printf "Apache ${CYAN}------->${RESET} "
brew list --versions httpd &> /dev/null && brew list --versions httpd | awk '{print $2}' && APACHE=1 || printf "${RED}not installed${RESET}\n"
printf "MySQL ${CYAN}-------->${RESET} "
brew list --versions mysql &> /dev/null && brew list --versions mysql | awk '{print $2}' && MYSQL=1 || printf "${RED}not installed${RESET}\n"
printf "PHP ${CYAN}---------->${RESET} "
brew list --versions php &> /dev/null && brew list --versions php | awk '{print $2}' && PHP=1 || printf "${RED}not installed${RESET}\n"
printf "phpMyAdmin ${CYAN}--->${RESET} "
brew list --versions phpmyadmin &> /dev/null && brew list --versions phpmyadmin | awk '{print $2}' && PHPMYADMIN=1 || printf "${RED}not installed${RESET}\n"

if [[ $HOMEBREW == 1 && $APACHE == 1 && $MYSQL == 1 && $PHP == 1 && $PHPMYADMIN == 1 ]]; then
    STACK=1
fi

printf "\n"

printf "Service Status:\n"
printf "~~~~~~~~~~~~~~~\n"
printf "Apache ${CYAN}------->${RESET} " && [[ $APACHE == 1 ]] && brew services | grep httpd | awk '{print $2}' || printf "${RED}not available${RESET}\n"
printf "MySQL ${CYAN}-------->${RESET} " && [[ $MYSQL == 1 ]] && brew services | grep mysql | awk '{print $2}' || printf "${RED}not available${RESET}\n"
printf "PHP ${CYAN}---------->${RESET} " && [[ $PHP == 1 ]] && brew services | grep php | awk '{print $2}' || printf "${RED}not available${RESET}\n"

printf "\n"

if [[ $STACK == 1 ]]; then
    BREW_PREFIX=$(brew --prefix)
    DOCUMENT_ROOT=$(grep -F "DocumentRoot \"" "$BREW_PREFIX/etc/httpd/httpd.conf" | awk '{print substr($2, 2, length($2)-2);}')
    printf "${CYAN}Where to put website files?${RESET} $DOCUMENT_ROOT\n"
    printf "${CYAN}How to test your PHP setup?${RESET} http://localhost/phpinfo.php\n"
    printf "${CYAN}phpMyAdmin:${RESET} http://localhost/phpmyadmin (user: root, no password)\n"
    printf "\n"
fi

printf "Stack Commands:\n"
printf "~~~~~~~~~~~~~~~\n"
[[ $STACK == 0 ]] && printf "${CYAN}${UNDERLINE}I${RESET}${CYAN}nstall${RESET}  Install the PHP stack.\n"
[[ $STACK == 1 ]] && printf "${CYAN}${UNDERLINE}U${RESET}${CYAN}pdate${RESET}   Update all packages.\n"
[[ $STACK == 1 ]] && printf "${CYAN}${UNDERLINE}R${RESET}${CYAN}estart${RESET}  Restart all PHP stack services.\n"
[[ $STACK == 1 ]] && printf "${CYAN}${UNDERLINE}S${RESET}${CYAN}top${RESET}     Stop all PHP stack services.\n"
[[ $STACK == 1 ]] && printf "${CYAN}DELETE${RESET}   Delete the entire PHP stack.\n"
printf "${CYAN}${UNDERLINE}Q${RESET}${CYAN}uit${RESET}     Quit this application.\n"

printf "\n"

printf "==> Enter command: " && read command

printf "\n"

if [[ $STACK == 0 ]]; then
    case "$command" in
        [iI]|[iI]nstall)
            [[ $HOMEBREW == 0 ]] && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && HOMEBREW=1
            [[ $APACHE == 0 ]] && brew install httpd && APACHE=1
            [[ $MYSQL == 0 ]] && brew install mysql && MYSQL=1
            [[ $PHP == 0 ]] && brew install php && PHP=1
            [[ $PHPMYADMIN == 0 ]] && brew install phpmyadmin && PHPMYADMIN=1

            BREW_PREFIX=$(brew --prefix)

            sed -i '' "s/Listen 8080/Listen 80/" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Enabled port 80 in Apache.\n"

            mkdir $HOME/www
            printf "[${GREEN}  OK  ${RESET}]  Created directory: $HOME/www\n"

            sed -i '' "s@$BREW_PREFIX/var/www@$HOME/www@g" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Changed document root to $HOME/www in Apache.\n"

            sed -i '' "s@$BREW_PREFIX/var/log/httpd/error_log@$HOME/www/error_log@g" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Changed location of error_log to $HOME/www in Apache.\n"

            sed -i '' "s@$BREW_PREFIX/var/log/httpd/access_log@$HOME/www/access_log@g" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Changed location of access_log to $HOME/www in Apache.\n"

            grep -F "LoadModule php_module $BREW_PREFIX/opt/php/lib/httpd/modules/libphp.so" "$BREW_PREFIX/etc/httpd/httpd.conf" &> /dev/null || printf "\nLoadModule php_module $BREW_PREFIX/opt/php/lib/httpd/modules/libphp.so\n" >> $BREW_PREFIX/etc/httpd/httpd.conf
            printf "[${GREEN}  OK  ${RESET}]  Enabled PHP in Apache (1/3).\n"

ENABLE_PHP=$(cat <<EOF
<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
EOF
)
            grep -F "<FilesMatch \.php$>" "$BREW_PREFIX/etc/httpd/httpd.conf" &> /dev/null || printf "\n$ENABLE_PHP\n" >> $BREW_PREFIX/etc/httpd/httpd.conf
            printf "[${GREEN}  OK  ${RESET}]  Enabled PHP in Apache (2/3).\n"

            sed -i '' "s/DirectoryIndex index.html/DirectoryIndex index.php index.html/" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Enabled PHP in Apache (3/3).\n"

            sed -i '' "s@#LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@LoadModule rewrite_module lib/httpd/modules/mod_rewrite.so@g" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Enabled rewrite module in Apache (1/2).\n"

            sed -i '' "s/AllowOverride None/AllowOverride All/g" "$BREW_PREFIX/etc/httpd/httpd.conf"
            printf "[${GREEN}  OK  ${RESET}]  Enabled rewrite module in Apache (2/2).\n"

ENABLE_PHPMYADMIN=$(cat <<EOF
Alias /phpmyadmin $BREW_PREFIX/share/phpmyadmin
<Directory $BREW_PREFIX/share/phpmyadmin/>
    Options Indexes FollowSymLinks MultiViews
    AllowOverride All
    <IfModule mod_authz_core.c>
        Require all granted
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order allow,deny
        Allow from all
    </IfModule>
</Directory>
EOF
)
            grep -F "Alias /phpmyadmin $BREW_PREFIX/share/phpmyadmin" "$BREW_PREFIX/etc/httpd/httpd.conf" &> /dev/null || printf "\n$ENABLE_PHPMYADMIN\n" >> $BREW_PREFIX/etc/httpd/httpd.conf
            printf "[${GREEN}  OK  ${RESET}]  Enabled phpMyAdmin in Apache.\n"

            sed -i '' "s/\$cfg\['blowfish_secret'\] = '';/\$cfg\['blowfish_secret'\] = '12345678901234567890123456789012';/" "$BREW_PREFIX/etc/phpmyadmin.config.inc.php"
            printf "[${GREEN}  OK  ${RESET}]  Filled in blowfish secret in phpMyAdmin.\n"

            sed -i '' "s/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = false;/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = true;/" "$BREW_PREFIX/etc/phpmyadmin.config.inc.php"
            printf "[${GREEN}  OK  ${RESET}]  Enabled passwordless login in phpMyAdmin.\n"

cat << EOF > $HOME/www/phpinfo.php
<?php phpinfo(); ?>

EOF
            printf "[${GREEN}  OK  ${RESET}]  Created file: $HOME/www/phpinfo.php\n"

            brew services start httpd
            brew services start mysql
            brew services start php

            [[ $HOMEBREW == 1 && $APACHE == 1 && $MYSQL == 1 && $PHP == 1 && $PHPMYADMIN == 1 ]] && printf "\n[${GREEN}  OK  ${RESET}]  PHP stack is installed.\n" && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/getphporg/getphp/HEAD/getphp-mac.sh)" || printf "\n[${RED}  Error  ${RESET}]  PHP stack is not installed.\n"
            ;;
        [qQ]|[qQ]uit)
            printf "[${GREEN}  OK  ${RESET}]  Goodbye!\n"
            ;;
        *)
            printf "[${RED}  Error  ${RESET}]  Command not recognized.\n"
            ;;
    esac
elif [[ $STACK == 1 ]]; then
    case "$command" in
        [uU]|[uU]pdate)
            brew update && brew upgrade && brew autoremove && brew cleanup && printf "\n[${GREEN}  OK  ${RESET}]  Your PHP stack is up to date.\n" || printf "\n[${RED}  Error  ${RESET}]  Update failed.\n"
            ;;
        [rR]|[rR]estart)
            brew services restart httpd && brew services restart mysql && brew services restart php && printf "\n[${GREEN}  OK  ${RESET}]  Restarted all PHP stack services.\n" || printf "\n[${RED}  Error  ${RESET}]  Failed to restart PHP stack services.\n"
            ;;
        [sS]|[sS]top)
            brew services stop httpd && brew services stop mysql && brew services stop php && printf "\n[${GREEN}  OK  ${RESET}]  Stopped all PHP stack services.\n" || printf "\n[${RED}  Error  ${RESET}]  Failed to stop PHP stack services.\n"
            ;;
        DELETE)
            brew services stop httpd && brew services stop mysql && brew services stop php && brew uninstall httpd && brew uninstall mysql && brew uninstall php && brew uninstall phpmyadmin && brew autoremove && brew cleanup && rm -rf $BREW_PREFIX/etc/httpd/httpd.conf && printf "[${GREEN}  OK  ${RESET}]  Deleted file: $BREW_PREFIX/etc/httpd/httpd.conf\n" && rm -rf $BREW_PREFIX/etc/phpmyadmin.config.inc.php && printf "[${GREEN}  OK  ${RESET}]  Deleted file: $BREW_PREFIX/etc/phpmyadmin.config.inc.php\n" && printf "\n[${GREEN}  OK  ${RESET}]  PHP stack is deleted.\n" || printf "\n[${RED}  Error  ${RESET}]  Failed to delete the PHP stack.\n"
            ;;
        [qQ]|[qQ]uit)
            printf "[${GREEN}  OK  ${RESET}]  Active services keep running.\n"
            printf "[${GREEN}  OK  ${RESET}]  Goodbye!\n"
            ;;
        *)
            printf "[${RED}  Error  ${RESET}]  Command not recognized.\n"
            ;;
    esac
fi

printf "\n"
