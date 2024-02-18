* Run:

  ```bash
  sudo apt update
  sudo apt install git -y
  git --version
  ```

* Configure the git user information by running:

  ```bash
  git config --global user.name "your name"
  git config --global user.email "your@email.com"
  git config --global core.editor "vim" # execute
  ```

* Create an SSH key-pair:

  ```bash
  ssh-keygen -t ed25519 -C "your@email"
  eval "$(ssh-agent -s)
  ssh-add ~/.ssh/id_ed25519
  cat ~/.ssh/id_ed25519.pub
  # Copy the contents of the key
  ```

* Navigate to Gitlab.com

* Login using SSO.

* Click on the profile icon.

* Choose preferences.

* Choose SSH keys from the left-hand navigation.

* Paste the contents of the public key in the box.

* Click add key.