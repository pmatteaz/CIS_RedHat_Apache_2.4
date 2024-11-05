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

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_section "Verifica CIS 5.6: Rimozione Script test-cgi"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    CGI_BIN_DIR="/var/www/cgi-bin"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    CGI_BIN_DIR="/usr/lib/cgi-bin"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array di possibili percorsi per test-cgi
declare -a TESTCGI_PATHS=(
    "$CGI_BIN_DIR/test-cgi"
    "$CGI_BIN_DIR/test-cgi.pl"
    "$CGI_BIN_DIR/test-cgi.cgi"
    "$CGI_BIN_DIR/test.cgi"
)

# Array per memorizzare i file trovati
declare -a found_files=()

print_section "Verifica File test-cgi"

# Funzione per controllare un singolo file
check_testcgi_file() {
    local file="$1"
    
    if [ -f "$file" ]; then
        echo -e "${RED}✗ Trovato file test-cgi: $file${NC}"
        
        # Verifica se è eseguibile
        if [ -x "$file" ]; then
            echo -e "${RED}  Il file è eseguibile${NC}"
        fi
        
        # Verifica il contenuto per confermare che sia effettivamente test-cgi
        if grep -qi "test.*cgi\|cgi.*test" "$file" 2>/dev/null; then
            echo -e "${RED}  Il file contiene codice test-cgi${NC}"
        fi
        
        # Verifica i permessi
        perms=$(stat -c '%a' "$file")
        owner=$(stat -c '%U' "$file")
        echo -e "${RED}  Permessi: $perms, Proprietario: $owner${NC}"
        
        found_files+=("$file")
    fi
}

# Verifica tutti i percorsi noti
for path in "${TESTCGI_PATHS[@]}"; do
    check_testcgi_file "$path"
done

# Cerca anche altri file potenziali test-cgi nella directory cgi-bin
if [ -d "$CGI_BIN_DIR" ]; then
    echo -e "\nCercando altri file test-cgi in $CGI_BIN_DIR..."
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            if grep -qi "test.*cgi\|cgi.*test" "$file" 2>/dev/null; then
                echo -e "${RED}✗ Trovato possibile file test-cgi: $file${NC}"
                found_files+=("$file")
            fi
        fi
    done < <(find "$CGI_BIN_DIR" -type f -print0)
fi

# Se ci sono file trovati, offri remediation
if [ ${#found_files[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#found_files[@]} file test-cgi.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_testcgi_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Backup di tutti i file trovati
        for file in "${found_files[@]}"; do
            echo "Backup di: $file"
            cp -p "$file" "$backup_dir/$(basename "$file")"
            # Salva anche i metadati del file
            stat "$file" > "$backup_dir/$(basename "$file").metadata"
        done
        
        # Rimozione dei file
        echo -e "\n${YELLOW}Rimozione file test-cgi...${NC}"
        
        for file in "${found_files[@]}"; do
            echo "Rimozione: $file"
            rm -f "$file"
        done
        
        # Verifica della configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                errors=0
                for file in "${found_files[@]}"; do
                    if [ -f "$file" ]; then
                        echo -e "${RED}✗ File ancora presente: $file${NC}"
                        ((errors++))
                    else
                        echo -e "${GREEN}✓ File rimosso con successo: $file${NC}"
                    fi
                done
                
                if [ $errors -eq 0 ]; then
                    echo -e "\n${GREEN}✓ Tutti i file test-cgi sono stati rimossi con successo${NC}"
                    
                    # Test pratico
                    echo -e "\n${YELLOW}Esecuzione test di accesso...${NC}"
                    for path in "${TESTCGI_PATHS[@]}"; do
                        web_path=${path#/var/www}
                        web_path=${web_path#/usr/lib}
                        if curl -s -I "http://localhost$web_path" 2>/dev/null | grep -q "200 OK"; then
                            echo -e "${RED}✗ Lo script test-cgi è ancora accessibile via web: $web_path${NC}"
                        else
                            echo -e "${GREEN}✓ Lo script test-cgi non è più accessibile: $web_path${NC}"
                        fi
                    done
                    
                    # Verifica directory CGI
                    echo -e "\n${YELLOW}Verifica sicurezza directory CGI...${NC}"
                    if [ -d "$CGI_BIN_DIR" ]; then
                        cgi_perms=$(stat -c '%a' "$CGI_BIN_DIR")
                        cgi_owner=$(stat -c '%U:%G' "$CGI_BIN_DIR")
                        if [[ "$cgi_perms" =~ ^7[0-7][0-7]$ ]]; then
                            echo -e "${RED}✗ Directory CGI ha permessi troppo permissivi: $cgi_perms${NC}"
                        else
                            echo -e "${GREEN}✓ Directory CGI ha permessi appropriati: $cgi_perms${NC}"
                        fi
                        echo "Proprietario:Gruppo della directory CGI: $cgi_owner"
                    fi
                    
                else
                    echo -e "\n${RED}✗ Alcuni file non sono stati rimossi correttamente${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            for file in "${found_files[@]}"; do
                if [ -f "$backup_dir/$(basename "$file")" ]; then
                    cp -p "$backup_dir/$(basename "$file")" "$file"
                fi
            done
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun file test-cgi trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory CGI controllata: $CGI_BIN_DIR"
echo "2. Percorsi verificati:"
for path in "${TESTCGI_PATHS[@]}"; do
    echo "   - $path"
done
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La rimozione dello script test-cgi garantisce che:${NC}"
echo -e "${BLUE}- Non vengano esposti dettagli sulla configurazione CGI del server${NC}"
echo -e "${BLUE}- Si riduca la superficie di attacco${NC}"
echo -e "${BLUE}- Non si rivelino informazioni potenzialmente utili agli attaccanti${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server web${NC}"
