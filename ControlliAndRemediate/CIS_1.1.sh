#!/bin/bash
# CIS 1.1: Ensure the Pre-Installation Planning Checklist Has Been Implemented
# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Funzione per stampare intestazioni delle sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Funzione per verificare e creare un file se non esiste
check_and_create_file() {
    local file=$1
    if [[ ! -f "$file" ]]; then
        echo -e "${YELLOW}File $file non trovato. Creazione...${NC}"
        touch "$file" 2>/dev/null || {
            echo -e "${RED}Errore nella creazione di $file${NC}"
            return 1
        }
        echo -e "${GREEN}File $file creato con successo${NC}"
    fi
}

# Funzione per verificare e creare una directory se non esiste
check_and_create_dir() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        echo -e "${YELLOW}Directory $dir non trovata. Creazione...${NC}"
        mkdir -p "$dir" 2>/dev/null || {
            echo -e "${RED}Errore nella creazione di $dir${NC}"
            return 1
        }
        echo -e "${GREEN}Directory $dir creata con successo${NC}"
    fi
}

print_section "Verifica CIS 1.1: Pre-Installation Planning Checklist"

# Array per tenere traccia dei problemi trovati
declare -a issues_found

# 1. Verifica delle policy di sicurezza
print_section "Verifica Policy di Sicurezza"
if [[ ! -d "/etc/security" ]]; then
    issues_found+=("Directory /etc/security non trovata")
else
    echo -e "${GREEN}✓ Directory /etc/security presente${NC}"
    
    # Verifica file di policy comuni
    for policy_file in limits.conf access.conf pwquality.conf; do
        if [[ ! -f "/etc/security/$policy_file" ]]; then
            issues_found+=("File di policy /etc/security/$policy_file non trovato")
        else
            echo -e "${GREEN}✓ File di policy $policy_file presente${NC}"
        fi
    done
fi

# 2. Verifica Firewall
print_section "Verifica Firewall"

if command_exists iptables; then
    echo -e "${GREEN}✓ iptables installato${NC}"
    
    # Verifica regole firewall per porte HTTP/HTTPS
    http_rules=$(iptables -L INPUT -n | grep -E "dpt:(80|443)")
    if [[ -z "$http_rules" ]]; then
        issues_found+=("Regole firewall per porte HTTP/HTTPS non trovate")
    else
        echo -e "${GREEN}✓ Regole firewall per HTTP/HTTPS presenti${NC}"
    fi
else
    issues_found+=("iptables non installato")
fi

# 3. Verifica Logging
print_section "Verifica Logging"

if command_exists rsyslog; then
    echo -e "${GREEN}✓ rsyslog installato${NC}"
    
    # Verifica configurazione rsyslog
    if ! grep -q "^*.* @" /etc/rsyslog.conf 2>/dev/null; then
        issues_found+=("Logging remoto non configurato in rsyslog")
    else
        echo -e "${GREEN}✓ Logging remoto configurato${NC}"
    fi
else
    issues_found+=("rsyslog non installato")
fi

# 4. Verifica Servizi
print_section "Verifica Servizi di Rete"

if command_exists netstat; then
    echo -e "${GREEN}✓ netstat disponibile${NC}"
    echo "Servizi in ascolto:"
    netstat -tulpn 2>/dev/null || echo -e "${RED}Errore nell'esecuzione di netstat${NC}"
else
    issues_found+=("netstat non installato")
fi

# Mostra problemi trovati e offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    print_section "Problemi Trovati"
    for issue in "${issues_found[@]}"; do
        echo -e "${RED}✗ $issue${NC}"
    done
    
    echo -e "\n${YELLOW}Vuoi procedere con la remediation automatica? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # 1. Configura directory e file di sicurezza
        check_and_create_dir "/etc/security"
        for policy_file in limits.conf access.conf pwquality.conf; do
            check_and_create_file "/etc/security/$policy_file"
        done
        
        # 2. Configura firewall base
        if command_exists iptables; then
            echo "Configurazione regole firewall di base..."
            iptables -A INPUT -p tcp --dport 80 -j ACCEPT
            iptables -A INPUT -p tcp --dport 443 -j ACCEPT
            echo -e "${GREEN}✓ Regole firewall configurate${NC}"
        else
            echo "Installazione iptables..."
            yum install -y iptables-services || apt-get install -y iptables
        fi
        
        # 3. Configura logging
        if ! command_exists rsyslog; then
            echo "Installazione rsyslog..."
            yum install -y rsyslog || apt-get install -y rsyslog
        fi
        
        # Configura logging remoto se non presente
        if ! grep -q "^*.* @" /etc/rsyslog.conf; then
            echo "Configurazione logging remoto..."
            read -p "Inserisci l'indirizzo del server di log (formato: server:porta): " logserver
            echo "*.* @$logserver" >> /etc/rsyslog.conf
            systemctl restart rsyslog
            echo -e "${GREEN}✓ Logging remoto configurato${NC}"
        fi
        
        print_section "Remediation Completata"
        echo -e "${GREEN}La maggior parte dei problemi è stata risolta. Verifica manualmente la configurazione.${NC}"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_1.1
        backup_dir="/root/apache_preinstall_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        # Copia file di configurazione importanti
        cp -r /etc/security "$backup_dir/"
        iptables-save > "$backup_dir/iptables_rules"
        cp /etc/rsyslog.conf "$backup_dir/"
        
        echo -e "${GREEN}Backup della configurazione salvato in $backup_dir${NC}"
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun problema critico trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica la configurazione del firewall con: iptables -L"
echo "2. Controlla i log con: tail -f /var/log/syslog o /var/log/messages"
echo "3. Monitora i servizi attivi con: netstat -tulpn"
echo -e "\n${BLUE}Ricorda di rivedere manualmente tutte le configurazioni di sicurezza${NC}"
