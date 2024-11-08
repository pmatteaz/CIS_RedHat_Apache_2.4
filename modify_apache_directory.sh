#!/bin/bash

modify_apache_directory() {
    local file="$1"          # File di configurazione Apache
    local directives="$2"    # Direttive da modificare/inserire (formato: "directive1 value1;directive2 value2")
    local directory="/var/www/httpd"  # Directory fissa
    local temp_file=$(mktemp)
    local in_section=false
    local section_found=false
    local changes_made=false

    # Verifica se il file esiste
    if [ ! -f "$file" ]; then
        echo "Errore: Il file $file non esiste"
        return 1
    }

    # Converti le direttive in un array
    IFS=';' read -ra DIRECTIVE_ARRAY <<< "$directives"

    # Leggi il file riga per riga
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^[[:space:]]*\<Directory[[:space:]]*\"$directory\"\> ]]; then
            in_section=true
            section_found=true
            echo "$line"
            
            # Aggiungi o modifica le direttive
            for directive in "${DIRECTIVE_ARRAY[@]}"; do
                IFS=' ' read -r dir_name dir_value <<< "$directive"
                local directive_added=false
                
                # Leggi le prossime righe fino alla fine della sezione
                while IFS= read -r next_line; do
                    if [[ $next_line =~ ^[[:space:]]*\</Directory\> ]]; then
                        # Se la direttiva non è stata ancora aggiunta, aggiungila prima della chiusura
                        if [ "$directive_added" = false ]; then
                            echo "    $dir_name $dir_value"
                            changes_made=true
                        fi
                        echo "$next_line"
                        break
                    elif [[ $next_line =~ ^[[:space:]]*$dir_name[[:space:]] ]]; then
                        # Sostituisci la direttiva esistente
                        echo "    $dir_name $dir_value"
                        directive_added=true
                        changes_made=true
                        continue
                    else
                        echo "$next_line"
                    fi
                done
            done
            in_section=false
        elif [ "$in_section" = false ]; then
            echo "$line"
        fi
    done < "$file" > "$temp_file"

    # Se la sezione non esiste, aggiungila alla fine del file
    if [ "$section_found" = false ]; then
        echo -e "\n<Directory \"$directory\">" >> "$temp_file"
        for directive in "${DIRECTIVE_ARRAY[@]}"; do
            echo "    $directive" >> "$temp_file"
        done
        echo "</Directory>" >> "$temp_file"
        changes_made=true
    fi

    # Se sono state fatte modifiche, crea un backup e applica le modifiche
    if [ "$changes_made" = true ]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        mv "$temp_file" "$file"
        echo "Modifiche applicate con successo. Backup creato."
    else
        rm "$temp_file"
        echo "Nessuna modifica necessaria."
    fi
}

# Funzione di validazione delle direttive Apache comuni
validate_apache_directive() {
    local directive="$1"
    local value="$2"

    case $directive in
        "Options")
            if [[ ! $value =~ ^(None|All|FollowSymLinks|Indexes|MultiViews|SymLinksIfOwnerMatch|ExecCGI)( *(None|All|FollowSymLinks|Indexes|MultiViews|SymLinksIfOwnerMatch|ExecCGI))*$ ]]; then
                return 1
            fi
            ;;
        "AllowOverride")
            if [[ ! $value =~ ^(None|All|AuthConfig|FileInfo|Indexes|Limit)( *(None|All|AuthConfig|FileInfo|Indexes|Limit))*$ ]]; then
                return 1
            fi
            ;;
        "Require")
            if [[ ! $value =~ ^(all|not|valid-user|user|group|env|host|local|expr) ]]; then
                return 1
            fi
            ;;
        *)
            # Per altre direttive, accetta qualsiasi valore
            return 0
            ;;
    esac
    return 0
}

# Esempio di utilizzo:
# modify_apache_directory "/etc/apache2/apache2.conf" "Options FollowSymLinks;AllowOverride All;Require all granted"
