#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
YELLOW='\033[1;33m'

# Funzione per creare un file di una dimensione specifica (in bytes)
create_test_file() {
    local size=$1
    local file="test_file_${size}.dat"
    dd if=/dev/zero of="$file" bs=1 count=$size 2>/dev/null
    echo "$file"
}

# Funzione per testare l'upload
test_upload() {
    local url=$1
    local file=$2
    local size=$3
    
    echo -e "${YELLOW}Testing upload with file size: $size bytes${NC}"
    
    # Effettua l'upload e cattura il codice di risposta HTTP
    response=$(curl -s -w "%{http_code}" -X POST \
        -H "Content-Type: multipart/form-data" \
        -F "file=@$file" \
        "$url")
    
    http_code=${response: -3}
    
    # Verifica il codice di risposta
    if [[ $http_code -eq 413 ]]; then
        echo -e "${RED}✗ Upload bloccato (HTTP 413) - LimitRequestBody funzionante${NC}"
        return 0
    elif [[ $http_code -eq 200 ]]; then
        echo -e "${GREEN}✓ Upload riuscito (HTTP 200) - Dimensione accettata${NC}"
        return 1
    else
        echo -e "${YELLOW}! Risposta inattesa (HTTP $http_code)${NC}"
        return 2
    fi
}

# Controllo argomenti
if [ "$#" -lt 2 ]; then
    echo "Uso: $0 <URL> <dimensione_limite_presunta>"
    echo "Esempio: $0 http://example.com/upload 1048576"
    exit 1
fi

URL=$1
EXPECTED_LIMIT=$2

# Array di dimensioni di test (in bytes)
declare -a TEST_SIZES=(
    $((EXPECTED_LIMIT - 1024))  # Poco sotto il limite
    $EXPECTED_LIMIT             # Al limite esatto
    $((EXPECTED_LIMIT + 1024))  # Poco sopra il limite
    $((EXPECTED_LIMIT * 2))     # Doppio del limite
)

# Esegui i test per ogni dimensione
for size in "${TEST_SIZES[@]}"; do
    test_file=$(create_test_file $size)
    test_upload "$URL" "$test_file" "$size"
    rm -f "$test_file"
    echo "----------------------------------------"
done

echo -e "\n${YELLOW}Test completati${NC}"
echo "Se hai visto errori 413 per file più grandi del limite,"
echo "e 200 per file più piccoli, LimitRequestBody è configurato correttamente."
