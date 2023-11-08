#!/bin/bash

#source variable data from an answer file
source git-gpg-setup.vars

DATE_NOW=$(date +"%Y-%m-%d")
echo $DATE_NOW

OS_FLAV=$(cat /etc/os-release | grep ^NAME | tr -d "=\"" | sed s/NAME// | tr [:upper:] [:lower:])

if [ "$OS_FLAV" == "ubuntu" ]; then
  GIT_PRESENT=$(dpkg -L git | grep bin/git$)
  if [ -z "$GIT_PRESENT" ]; then
    sudo apt -y install git
  fi
fi
echo ''
git --version

GIT_FILE="$HOME/.gitconfig"
echo "checking for existing configuration in $GIT_FILE ..."
if [ -f $GIT_FILE ]; then
  TARGET_STR="name = $USER"
  STR_SEARCH=$(cat $GIT_FILE | grep "$TARGET_STR")
  if [ -z "$STR_SEARCH" ]; then
    echo "Configuring git user.name ..."
    git config --global user.name "$USER"
    sleep 1
  else
    echo "found:"
    echo "$TARGET_STR"
    echo "skipping git user.name configuration ..."
    sleep 1
  fi
  TARGET_STR="email = $GIT_EMAIL"
  STR_SEARCH=$(cat $GIT_FILE | grep "$TARGET_STR")
  if [ -z "$STR_SEARCH" ]; then
    echo "Configuring git user.email ..."
    git config --global user.email $GIT_EMAIL
    sleep 1
  else
    echo "found:"
    echo "$TARGET_STR"
    echo "skipping git user.email configuration ..."
    sleep 1
  fi
  TARGET_STR="editor = $EDITOR"
  STR_SEARCH=$(cat $GIT_FILE | grep "$TARGET_STR")
  if [ -z "$STR_SEARCH" ]; then
    echo "Configuring git core.editor ..."
    git config --global core.editor $EDITOR
    sleep 1
  else
    echo "found:"
    echo "$TARGET_STR"
    echo "skipping git core.editor configuration ..."
    sleep 1
  fi
  TARGET_STR="defaultBranch = $DEF_BRANCH"
  STR_SEARCH=$(cat $GIT_FILE | grep "$TARGET_STR")
  if [ -z "$STR_SEARCH" ]; then
    echo "Configuring git init.defaultBranch ..."
    git config --global init.defaultBranch $DEF_BRANCH
    sleep 1
  else
    echo "found:"
    echo "$TARGET_STR"
    echo "skipping git init.defaultBranch configuration ..."
    sleep 1
  fi
else
  echo "Configuring git ..."
  git config --global user.name $USER
  git config --global user.email $GIT_EMAIL
  git config --global core.editor $EDITOR
  git config --global init.defaultBranch $DEF_BRANCH
  sleep 1
fi

NUM_KEYS=$(gpg --list-keys | grep ^.ub | wc -l)
echo -e "\nnumber of keys found $NUM_KEYS"
if [ $NUM_KEYS -gt 0 ]; then
  echo -e "skipping key creation ..."
  SKIP_KEY_CREATION="true"
  sleep 1
else
  SKIP_KEY_CREATION="false"

cat >"foo" <<EOF
    %echo Generating OpenPGP key
    Key-Type: RSA
    Key-Length: 4096
    Key-Usage: cert
    Subkey-Type: RSA
    Subkey-Length: 4096
    Subkey-Usage: auth
    Name-Real: $USER
    Name-Comment: general purpose signing key
    Name-Email: $GIT_EMAIL
    Creation-Date: $DATE_NOW
    Expire-Date: 0
    #preferred key server URL (use own)
    #Keyserver:
    #use this to create a revocation key?
    #Revoker: 1:{{ var_revoker_fp }} [sensitive]
    Handle: general purpose signing key
    Passphrase: $PASS
    %commit
    %echo done
EOF
gpg --batch --generate-key foo
  rm foo

  echo "Key creation complete, verifying..."
  gpg --list-secret-keys --keyid-format=long

  echo "Creating subkeys..."
  FPR=$(gpg --list-options show-only-fpr-mbox --list-secret-keys | awk '{print $1}')

  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --quick-add-key $FPR rsa4096 sign 0
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --quick-add-key $FPR rsa4096 encrypt 0
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --quick-add-key $FPR ed25519 sign 0
  #gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --quick-add-key $FPR ed25519 encrypt 0
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --quick-add-key $FPR ed25519 auth 0
  gpg --list-keys
  gpg --list-secret-keys --keyid-format=long

  KEYFP=$(gpg --list-secret-keys --keyid-format=long | grep rsa4096 | grep '[S]' | awk -F" " '{print $2}' | awk -F"/" '{print $2}')

  GITSERVER_FILE="upload-to-profile-on-git-server.key"

  #for gitlab or github
  gpg --armor --export $KEYFP > $GITSERVER_FILE

  #part of local git config
  echo "Configuring git for GPG signing..."
  git config --global user.signingkey $KEYFP

  #sign everything
  git config --global commit.gpgsign true


  echo "Creating a revocation certificate..."
  KEYFP=$(gpg --list-secret-keys --keyid-format=long | grep "^sec" | awk -F" " '{print $2}' | awk -F"/" '{print $2}')
  echo $KEYFP

  REVOKE_FILE="revocation-cert_${GIT_EMAIL}_${DATE_NOW}.asc"

{
  echo y
  echo 0
  echo Backup revocation certificate
  echo
  echo y
  echo "$PASS"
} | gpg --command-fd=0 --pinentry-mode=loopback --status-fd=1 --gen-revoke $KEYFP > $REVOKE_FILE

  echo "Creating a backup..."
  PRIVKEY_FILE="backup_${GIT_EMAIL}_${DATE_NOW}.priv.asc"
  SUBKEY_FILE="backup_${GIT_EMAIL}_subs_${DATE_NOW}.priv.asc"
  PUBKEY_FILE="backup_${GIT_EMAIL}_${DATE_NOW}.pub.asc"
  OWNERTRUST_FILE="backup_${GIT_EMAIL}_ownertrust_${DATE_NOW}.txt"
  RESTORE_FILE="restore_script_${GIT_EMAIL}.bash"

  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --export-secret-keys --armor $GIT_EMAIL > $PRIVKEY_FILE
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --export-secret-subkeys --armor $GIT_EMAIL > $SUBKEY_FILE
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --export --armor $GIT_EMAIL > $PUBKEY_FILE
  gpg --batch --pinentry-mode=loopback --passphrase "$PASS" --export-ownertrust  > $OWNERTRUST_FILE

cat << "EOF" > $RESTORE_FILE
#!/bin/bash
#run this on a new machine to restore gpg keys

gpg --import $PUBKEY_FILE
gpg --import $PRIVKEY_FILE
gpg --import $SUBKEY_FILE
gpg --import-ownertrust $OWNERTRUST_FILE

{
  echo trust
  echo 5
} | gpg --command-fd-0 --pinentry-mode=loopback --status-fd-1 --edit-key $GIT_EMAIL
EOF

  BACKUP_FILE="gpg_backup_${GIT_EMAIL}_${DATE_NOW}.tar.gz"

  tar -czvf $BACKUP_FILE $PRIVKEY_FILE $SUBKEY_FILE $PUBKEY_FILE $OWNERTRUST_FILE $REVOKE_FILE $RESTORE_FILE
  echo "Displaying the contents of the backup file ${BACKUP_FILE}:"
  tar -ztvf $BACKUP_FILE

  rm $PRIVKEY_FILE $SUBKEY_FILE $PUBKEY_FILE $OWNERTRUST_FILE $REVOKE_FILE $RESTORE_FILE
fi

if [ ! -d "$REPO_DIR" ]; then
  echo -e "\nNo repo directory found, creating one...\n"
  mkdir $REPO_DIR
fi


TARGET="$HOME/.profile"   #or .bashrc or
if [ -f "$TARGET" ]; then
  BACKUP="$HOME/.oldprofile"
  STR_SEARCH=$(cat $TARGET | grep 'export GPG_TTY=$(tty)')
  if [ -z "$STR_SEARCH" ]; then
    echo "Updating .profile for GPG..."
    cp $TARGET $BACKUP
    echo ' ' >> $TARGET
    echo 'export GPG_TTY=$(tty)' >> $TARGET
    echo ' ' >> $TARGET
    diff $BACKUP $TARGET
    PROFILE_FILE="$TARGET"
  else
    echo -e "\n.profile is up-to-date"
  fi
fi
echo RELOADAGENT | gpg-connect-agent

echo "$REPO_DIR" > .git_setup_has_been_run

echo " "
echo "Congrats, your environment is all set up now for git and GPG.  Next steps include:"
echo "- source your bash profile file ($PROFILE_FILE)"
echo "- Logging into GitLab/GitHub and installing the gpg public key in $GITSERVER_FILE under your profile"
echo "- Moving $BACKUP_FILE to a USB stick or other device and locking it away (perhaps also printing the contents)"
echo "- Uploading your key to a key server"
