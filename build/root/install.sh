#!/bin/bash

# exit script if return code != 0
set -e

# release tag name from buildx arg, stripped of build ver using string manipulation
RELEASETAG="${1//-[0-9][0-9]/}"

# target arch from buildx arg
TARGETARCH="${2}"

if [[ -z "${RELEASETAG}" ]]; then
	echo "[warn] Release tag name from build arg is empty, exiting script..."
	exit 1
fi

if [[ -z "${TARGETARCH}" ]]; then
	echo "[warn] Target architecture name from build arg is empty, exiting script..."
	exit 1
fi

# set secret
export GH_TOKEN="${2}"

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/binhex/scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /root
mv /tmp/scripts-master/shell/arch/docker/*.sh /usr/local/bin/


# pacman packages
####

# define pacman packages
pacman_packages="libcups fontconfig libx264 libvpx github-cli"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# define aur packages
aur_packages="jre8"

# call aur install script (arch user repo)
source aur.sh

# github releases
####

# download airsonic
release=$(gh release list --repo airsonic-advanced/airsonic-advanced | grep -P -m 1 'Pre-release' | xargs | rev | cut -d ' ' -f2 | rev)
gh release download --repo airsonic-advanced/airsonic-advanced "${release}" --pattern '*war' --dir '/opt/airsonic'

# download statically linked ffmpeg
ffmpeg_package_name="ffmpeg-release-static.tar.xz"
rcurl.sh -o "/tmp/${ffmpeg_package_name}" "https://github.com/binhex/packages/raw/master/static/${TARGETARCH}/ffmpeg/johnvansickle/${ffmpeg_package_name}"

# unpack and move binaries
mkdir -p "/tmp/unpack" && tar -xvf "/tmp/${ffmpeg_package_name}" -C "/tmp/unpack"
mv /tmp/unpack/ffmpeg*/ff* "/usr/bin/"

# container perms
####

# define comma separated list of paths
install_paths="/opt/airsonic,/home/nobody"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

cat <<'EOF' > /tmp/envvars_heredoc
export CONTEXT_PATH=$(echo "${CONTEXT_PATH}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${CONTEXT_PATH}" ]]; then
	echo "[info] CONTEXT_PATH defined as '${CONTEXT_PATH}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] CONTEXT_PATH not defined (via -e CONTEXT_PATH), defaulting to '/'" | ts '%Y-%m-%d %H:%M:%.S'
	export CONTEXT_PATH="/"
fi

export MAX_MEMORY=$(echo "${MAX_MEMORY}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${MAX_MEMORY}" ]]; then
	echo "[info] MAX_MEMORY defined as '${MAX_MEMORY}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] MAX_MEMORY not defined (via -e MAX_MEMORY), defaulting to '2046'" | ts '%Y-%m-%d %H:%M:%.S'
	export MAX_MEMORY="2046"
fi
EOF

# replace envvar placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
    s/# ENVVARS_PLACEHOLDER//g
    r /tmp/envvars_heredoc
}' /usr/local/bin/init.sh
rm /tmp/envvars_heredoc

# cleanup
cleanup.sh
