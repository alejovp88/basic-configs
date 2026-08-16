- i want to be able to set up my development environment in an easier way every time i switch to a new computer
- one important thing is that the configs should be thought for local development environment not for production 
- i want to create 2 script files, both oriented to Linux distributions one is debain/ubuntu and the other is arch Linux
- set the instructions to install, all of these should be performed via terminal
- have in mind these scripts should allow me to execute the installations with almost no interaction, i would say the only interaction should be requesting sudo password at the beginning of them because it will be needed for sure  

# common installation
- install git
- request the global credentials 'user.name' and the 'user.email'
- request the git password to be stored and used in the new projects
- install openvpn client to be able to connect to external VPN's
- create the 'Projects' directory under the path '$HOME'
- create the 'littleTaller' directory under the path '$HOME/Projects'
- create the 'AKI' directory under the path '$HOME/Projects'
- create the 'Personal' directory under the path '$HOME/Projects'
- install Google Chrome browser via terminal
- install brave browser (can use this page as doc https://brave.com/linux/)
- install Development IDE PhpStorm from this doc (https://www.jetbrains.com/help/phpstorm/installation-guide.html#snap)
- install Slack
- install Postman
- install Claude code CLI
- install steam
- install DBeaver Community to manage the databases

# debian/ubuntu distro
- install 'apt' and 'apt-get' packages to manage upcoming installations
- install docker, following the documentation https://docs.docker.com/desktop/setup/install/linux/ubuntu/
- enable the docker service to start automatically on boot (only the docker daemon, not the database services from the compose file)

# arch linux distro

- for this installations i think it will be a good starting point using these pages https://wiki.archlinux.org/ and https://aur.archlinux.org/
- install the 'yay' package to manage upcoming installations
- install docker, following the documentation https://wiki.archlinux.org/title/Docker#Installation, also can use this reference until the 'Paso 4' https://rubensa.wordpress.com/2025/09/18/como-instalar-docker-en-arch-linux-guia-paso-a-paso/
- enable the docker service to start automatically on boot (only the docker daemon, not the database services from the compose file)

# databases
i have several project and they use several databases so i need to create docker files for them and if possible configure the instances to allow remote connections. The data databases are 
- Mysql database 
- Postgres database
- Microsoft SQL Server