#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per stampare intestazioni delle sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_section "Backup Configurazione"

../Apache_backup_ConfigFile.sh

print_section "Start hardening!"

./CIS_2.2.sh
./CIS_2.3.sh
./CIS_2.5.sh
./CIS_2.7.sh
./CIS_2.8.sh
./CIS_2.9.sh
./CIS_3.1.sh
./CIS_3.2.sh
./CIS_3.3.sh
./CIS_3.4.sh
./CIS_3.5.sh
./CIS_3.6.sh
./CIS_3.7.sh
./CIS_3.8.sh
./CIS_3.9.sh
./CIS_3.10.sh
./CIS_3.11.sh
./CIS_3.12.sh
./CIS_4.1.sh
./CIS_4.3.sh
./CIS_4.4.sh
./CIS_5.1.sh
./CIS_5.7-enhanced.sh
./CIS_5.8.sh
./CIS_5.9.sh
./CIS_5.10.sh
./CIS_6.1.sh
./CIS_6.3.sh
./CIS_6.4.sh
#./CIS_6.5.sh
./CIS_7.1.sh
./CIS_7.3.sh
./CIS_7.4.sh
./CIS_7.5.sh
./CIS_7.6.sh
./CIS_7.8.sh
#./CIS_7.10.sh
./CIS_7.11.sh
./CIS_7.12.sh
./CIS_8.1.sh
./CIS_8.2.sh
./CIS_8.3-2.sh
./CIS_8.4.sh
#./CIS_9.1.sh
./CIS_9.2-3-4.sh
./CIS_9.5-6.sh
./CIS_10.1.sh
./CIS_10.2.sh
./CIS_10.3.sh
#./CIS_10.4.sh

print_section "Stop hardening "
