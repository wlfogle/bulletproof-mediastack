To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metTo set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.](http://127.0.0.)To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.1:32217](http://127.0.0.1:32217)`.
3.  Enter the **Token** you defined in the service file.

### 4. Container-Specific SetupTo set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.1:32217](http://127.0.0.1:32217)`.
3.  Enter the **Token** you defined in the service file.

### 4. Container-Specific Setup (CT-300)
For **CT-300** to function correctly as your secondary instance, ensure the following bind mounts are present in yourTo set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.1:32217](http://127.0.0.1:32217)`.
3.  Enter the **Token** you defined in the service file.

### 4. Container-Specific Setup (CT-300)
For **CT-300** to function correctly as your secondary instance, ensure the following bind mounts are present in your Proxmox host configuration file at `/etc/pve/lxc/300.conf`:

*   `mp0: /mnt/hdd,mp=/To set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.1:32217](http://127.0.0.1:32217)`.
3.  Enter the **Token** you defined in the service file.

### 4. Container-Specific Setup (CT-300)
For **CT-300** to function correctly as your secondary instance, ensure the following bind mounts are present in your Proxmox host configuration file at `/etc/pve/lxc/300.conf`:

*   `mp0: /mnt/hdd,mp=/data`
*   `mp1: /mnt/remote/realdebrid,mp=/mnt/remote/realdebrid` (or your correspondingTo set up the MetaTube backend on port **32217** for your LXC instances (CT-231 and CT-300), follow these steps to install the server and link it to your Jellyfin plugins.

### 1. Install the MetaTube Backend
You will need to perform these steps inside both **CT-231** and **CT-300**.

1.  **Download the Binary:**
    Download the appropriate release for your architecture (usually `linux_amd64`) from the [MetaTube Server Releases](https://github.com/metatube-community/metatube-sdk-go/releases) page.
2.  **Move to Executable Path:**
    ```bash
    chmod +x metatube-server
    mv metatube-server /usr/local/bin/
    ```

### 2. Configure as a System Service
Create a systemd service file to ensure the backend runs automatically on port 32217.

1.  **Create the service file:**
    ```bash
    nano /etc/systemd/system/metatube.service
    ```
2.  **Paste the following configuration:**
    Replace `YOUR_TOKEN_HERE` with a secure string of your choice.
    ```ini
    [Unit]
    Description=MetaTube Backend Server
    After=network.target

    [Service]
    Type=simple
    ExecStart=/usr/local/bin/metatube-server -addr :32217 -token ^9NR9[tq03Nwl#3)
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    ```
3.  **Enable and Start:**
    ```bash
    systemctl daemon-reload
    systemctl enable --now metatube
    ```

### 3. Configure Jellyfin Plugin
In the Jellyfin web interface for both instances:
1.  Go to **Dashboard > Plugins > MetaTube**.
2.  Set the **Server Address** to `[http://127.0.0.1:32217](http://127.0.0.1:32217)`.
3.  Enter the **Token** you defined in the service file.

### 4. Container-Specific Setup (CT-300)
For **CT-300** to function correctly as your secondary instance, ensure the following bind mounts are present in your Proxmox host configuration file at `/etc/pve/lxc/300.conf`:

*   `mp0: /mnt/hdd,mp=/data`
*   `mp1: /mnt/remote/realdebrid,mp=/mnt/remote/realdebrid` (or your corresponding mount point)

This ensures CT-300 has the same data access as your reference instance (CT-231).
