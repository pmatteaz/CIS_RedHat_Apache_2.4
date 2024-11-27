#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Verifica CIS 1.3: Installazione Apache da binari appropriati ==="

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verifica se rpm è disponibile
if ! command_exists rpm; then
    echo -e "${RED}ERROR: comando rpm non trovato. Questo script richiede un sistema basato su RPM.${NC}"
    exit 1
fi

# Verifica se Apache è installato
if ! rpm -q httpd >/dev/null 2>&1; then
    echo -e "${YELLOW}Apache (httpd) non è installato.${NC}"
    echo "Procedere con l'installazione dai repository ufficiali? (s/n)"
    read -r risposta
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        echo "Installazione di Apache in corso..."
        if yum install -y httpd mod_ssl openssl; then
            echo -e "${GREEN}Apache installato correttamente dai repository ufficiali.${NC}"
        else
            echo -e "${RED}Errore durante l'installazione di Apache.${NC}"
            exit 1
        fi
    else
        echo "Installazione annullata."
        exit 1
    fi
fi

# Verifica il venditore del pacchetto
vendor=$(rpm -qi httpd | grep "Vendor" )

# Lista dei vendor considerati affidabili
trusted_vendors=("Red Hat, Inc." "CentOS" "Fedora Project" "Rocky Enterprise Software Foundation" "AlmaLinux Unlimited")

vendor_trusted=0
for trusted_vendor in "${trusted_vendors[@]}"; do
    if [[ "$vendor" =~ "$trusted_vendor" ]]; then
        vendor_trusted=1
        break
    fi
done

if [ $vendor_trusted -eq 1 ]; then
    echo -e "${GREEN}✓ Apache è installato da un vendor affidabile: $vendor${NC}"
else
    echo -e "${RED}✗ Apache è installato da un vendor non verificato: $vendor${NC}"
    echo "Vuoi reinstallare Apache dai repository ufficiali? (s/n)"
    read -r risposta
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        echo "Rimozione della versione attuale di Apache..."
        systemctl stop httpd
        yum remove -y httpd mod_ssl
        echo "Installazione della versione ufficiale di Apache..."
        if yum install -y httpd mod_ssl openssl; then
            echo -e "${GREEN}Apache reinstallato correttamente dai repository ufficiali.${NC}"
            systemctl start httpd
        else
            echo -e "${RED}Errore durante la reinstallazione di Apache.${NC}"
            exit 1
        fi
    else
        echo "Remediation annullata."
        exit 1
    fi
fi

echo -e "\n=== Verifica completata ==="
