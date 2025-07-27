
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/Marlon5775/ProxmoxVE/main/misc/install.func)
# Copyright (c) 2025 community-scripts ORG
# Author: Marlon5775
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://beammp.com/

APP="beammp-server-web"

# --- Automatisch als normaler Benutzer ausführen, auch bei Pipe-Start ---
BEAMMP_USER="beammp"
# Bestimme den Pfad zu diesem Skript
if [ -n "$SCRIPT_PATH" ]; then
  SELF="$SCRIPT_PATH"
else
  SELF="$0"
fi
if [ "$(whoami)" = "root" ]; then
  if ! id "$BEAMMP_USER" &>/dev/null; then
    while true; do
      read -s -p "Set password for user $BEAMMP_USER: " BEAMMP_PASS
      echo
      read -s -p "Repeat password: " BEAMMP_PASS2
      echo
      if [[ -z "$BEAMMP_PASS" ]]; then
        echo "Password must not be empty."
      elif [[ "$BEAMMP_PASS" != "$BEAMMP_PASS2" ]]; then
        echo "Passwords do not match."
      else
        break
      fi
    done
    useradd -m -s /bin/bash "$BEAMMP_USER"
    echo "$BEAMMP_USER:$BEAMMP_PASS" | chpasswd
  fi
  chown -R "$BEAMMP_USER":"$BEAMMP_USER" /opt/beammp-servers 2>/dev/null || true
  chown -R "$BEAMMP_USER":"$BEAMMP_USER" /opt/beammp-web 2>/dev/null || true
  echo "$BEAMMP_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/beammp
  chmod 440 /etc/sudoers.d/beammp
  # Schreibe den User-Teil in eine temporäre Datei ab Marker
  TMPUSER=/tmp/beammp-user-install-$$.sh
  awk '/^###__USERPART__/{found=1;next} found' "$SELF" > "$TMPUSER"
  chmod +x "$TMPUSER"
  sudo -u "$BEAMMP_USER" -H SCRIPT_PATH="$SELF" bash "$TMPUSER"
  rm -f "$TMPUSER"
  exit
fi


# --- ab hier: User-Teil ---
###__USERPART__
# Load helper functions and set STD if not set
source <(curl -fsSL https://raw.githubusercontent.com/Marlon5775/ProxmoxVE/main/misc/install.func)
if [ -z "$STD" ]; then
  STD=""
fi


color
catch_errors

msg_info "Installing dependencies for BeamMP Server(s)"
sudo "$STD" apt-get update
sudo "$STD" apt-get install -y curl wget unzip sudo liblua5.3-0
sudo mkdir -p /opt/beammp-servers

read -p "How many BeamMP servers do you want to install? (default: 1): " SERVER_COUNT
SERVER_COUNT=${SERVER_COUNT:-1}


for i in $(seq 1 "$SERVER_COUNT"); do
  SERVER_DIR="/opt/beammp-servers/server${i}"
  sudo mkdir -p "$SERVER_DIR"
  msg_info "Downloading BeamMP Server $i"
  LATEST_URL=$(curl -s https://api.github.com/repos/BeamMP/BeamMP-Server/releases/latest | grep browser_download_url | grep debian.12 | grep x86_64 | cut -d '"' -f4 | head -n1)
  sudo wget -O "$SERVER_DIR/BeamMP-Server" "$LATEST_URL"
  sudo chmod +x "$SERVER_DIR/BeamMP-Server"
  msg_ok "BeamMP Server $i downloaded"
  msg_info "Running BeamMP Server $i once to generate config"
  (cd "$SERVER_DIR" && sudo ./BeamMP-Server || true)
  msg_ok "Config generated for server $i"
done



msg_info "Installing dependencies for BeamMP-Web"
sudo "$STD" apt-get install -y apache2 mariadb-server php php-mysql php-curl php-xml php-mbstring python3 python3-venv python3-pip unzip curl git composer jq


while true; do
  read -p "Enter MariaDB username to create: " DB_USER
  if [[ -z "$DB_USER" ]]; then
    echo "A username is required. Please enter a value."
  else
    break
  fi
done
while true; do
  read -s -p "Enter MariaDB password for $DB_USER: " DB_PASS
  echo
  if [[ -z "$DB_PASS" ]]; then
    echo "A password is required. Please enter a value."
  else
    break
  fi
done

msg_info "Creating MariaDB user and granting privileges..."
sudo mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT CREATE ON *.* TO '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON beammp_db.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;"
msg_ok "MariaDB user $DB_USER created and privileges granted."


cd /opt || exit
git clone https://github.com/Zyphro3D/BeamMP-web.git beammp-web
cd beammp-web || exit
cp install_config.json install_config.json.bak


# Sprache abfragen
while true; do
  read -p "Enter language (en/fr/de): " LANG
  if [[ "$LANG" =~ ^(en|fr|de)$ ]]; then
    break
  else
    echo "Please enter 'en', 'fr' or 'de'."
  fi
done

# IP automatisch ermitteln
IP=$(hostname -I | awk '{print $1}')
if [[ -z "$IP" ]]; then
  IP="127.0.0.1"
fi
msg_ok "Detected container IP: $IP"

# Instanzen automatisch anhand SERVER_COUNT
INSTANCE_COUNT=$SERVER_COUNT
INSTANCES_JSON=""
declare -a INSTANCE_NAMES
declare -a INSTANCE_PORTS
for i in $(seq 1 "$INSTANCE_COUNT"); do
  read -p "Enter name for instance $i: " INSTANCE_NAME
  while [[ -z "$INSTANCE_NAME" ]]; do
    echo "Name is required."
    read -p "Enter name for instance $i: " INSTANCE_NAME
  done
  read -p "Enter port for instance $i (e.g. 8081): " INSTANCE_PORT
  while [[ -z "$INSTANCE_PORT" ]]; do
    echo "Port is required."
    read -p "Enter port for instance $i (e.g. 8081): " INSTANCE_PORT
  done
  INSTANCE_NAMES+=("$INSTANCE_NAME")
  INSTANCE_PORTS+=("$INSTANCE_PORT")
  ROOT_BEAMMP="/opt/beammp-servers/server${i}"
  if [[ $i -gt 1 ]]; then
    INSTANCES_JSON+="      ,\n"
  fi
  INSTANCES_JSON+="      { \"name\": \"$INSTANCE_NAME\", \"port\": \"$INSTANCE_PORT\", \"root_beammp\": \"$ROOT_BEAMMP\" }"
done

USER_SYSTEM="beammp"
# install_config.json schreiben
cat > install_config.json <<EOF
{
  "db_user": "$DB_USER",
  "db_pass": "$DB_PASS",
  "user_system": "$USER_SYSTEM",
  "lang": "$LANG",
  "ip": "$IP",
  "instances": [
$INSTANCES_JSON
  ]
}
EOF
msg_ok "install_config.json created."

chmod +x Install.sh
sudo ./Install.sh
msg_ok "BeamMP-Web installed"

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access BeamMP-Web using the following URL:${CL}"
for i in $(seq 1 "$INSTANCE_COUNT"); do
  name="${INSTANCE_NAMES[$((i-1))]}"
  port="${INSTANCE_PORTS[$((i-1))]}"
  echo -e "${TAB}${GATEWAY}${BGN}${name}: http://${IP}:${port}${CL}"
done
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8081${CL}"
