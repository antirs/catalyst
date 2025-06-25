#!/bin/bash

source /tmp/chroot-functions.sh

for module_path in /usr/lib/*/site-packages/portage/__init__.py; do
	# Find the python interpreter
	interpreter=$(echo $module_path | cut -d/ -f4)

	buildpkgs=($($interpreter /tmp/build.py 2>/dev/null))
	[[ $? == 0 ]] && break
done

## Sanity check profile
if [[ ${#buildpkgs[@]} -eq 0 ]]; then
	echo "Your profile seems to be broken."
	echo "Could not build a list of build packages."
	echo "Double check your ${clst_port_conf}/make.profile link and the 'packages' files."
	exit 1
fi

# Setup our environment
[ -n "${clst_BINDIST}" ] && BINDIST="bindist"
BOOTSTRAP_USE="$(portageq envvar BOOTSTRAP_USE)"

FEATURES="${FEATURES} nodoc noman noinfo"

sed -i -e 's:BINPKG_COMPRESS="bzip2":BINPKG_COMPRESS="zstd":' \
	/usr/share/portage/config/make.globals

# We need to ensure the base stage3 has USE="bindist"
# if BINDIST is set to avoid issues with openssl / openssh
[ -e ${clst_make_conf} ] && echo "USE=\"${BINDIST} ${USE}\"" >> ${clst_make_conf}

# Preliminary support for BROOT update
if [[ "${EN_CATALYST_UPDATE_BROOT}" == "yes" ]] &&
	   [[ -n "${EN_CATALYST_BROOT}" ]] &&
	   [[ -n "${EN_CATALYST_PROFILE_BROOT}" ]]; then
	echo Update BROOT "(${EN_CATALYST_PROFILE_BROOT})": \
		 ROOT=/ PORTAGE_CONFIGROOT="${EN_CATALYST_BROOT}" emerge...
	ensure_broot "${EN_CATALYST_BROOT}" "${EN_CATALYST_PROFILE_BROOT}"
	while read en_clst_update_broot_command; do
		if [[ -n "${en_clst_update_broot_command}" ]]; then
			PORTAGE_CONFIGROOT="${EN_CATALYST_BROOT}" \
				ROOT=/ run_merge ${en_clst_update_broot_command}
		fi
	done < <(echo "${EN_CATALYST_UPDATE_BROOT_COMMANDS}")
fi

# Update stage3
if [ -n "${clst_update_seed}" ]; then
	if [ "${clst_update_seed}" == "yes" ]; then
		echo "Updating seed stage..."
		if [ -n "${clst_update_seed_command}" ]; then
			ROOT=/ run_merge --buildpkg=n "${clst_update_seed_command}"
		else
			ROOT=/ run_merge --buildpkg=n --update --deep --newuse @world
		fi
	elif [ "${clst_update_seed}" != "no" ]; then
		echo "Invalid setting for update_seed: ${clst_update_seed}"
		exit 1
	fi

	# reset emerge options for the target
	clst_update_seed=no setup_emerge_opts
else
	echo "Skipping seed stage update..."
fi

# Clear USE
[ -e ${clst_make_conf} ] && sed -i -e "/^USE=\"${BINDIST} ${USE}\"/d" ${clst_make_conf}

export ROOT="${clst_root_path}"
mkdir -p "$ROOT"

## START BUILD
# First, we drop in a known-good baselayout
[ -e ${clst_make_conf} ] && echo "USE=\"${USE} build\"" >> ${clst_make_conf}
run_merge --oneshot --nodeps --getbinpkg n sys-apps/baselayout
sed -i "/USE=\"${USE} build\"/d" ${clst_make_conf}

echo "$locales" > /etc/locale.gen
for etc in /etc "$ROOT"/etc; do
	echo "LANG=C.UTF-8" > ${etc}/env.d/02locale
done
update_env_settings

# Now, we install our packages
if [ -e ${clst_make_conf} ]; then
	echo "CATALYST_USE=\"-* build ${BINDIST} ${clst_CATALYST_USE}\"" >> ${clst_make_conf}
	echo "USE=\"\${CATALYST_USE} ${USE} ${BOOTSTRAP_USE} ${clst_HOSTUSE}\"" >> ${clst_make_conf}

	for useexpand in ${clst_HOSTUSEEXPAND}; do
		x="clst_${useexpand}"
		echo "${useexpand}=\"${!x}\"" \
		>> ${clst_make_conf}
	done
fi

# Preliminary support for SYSROOT builds
if [[ -n "${EN_CATALYST_SYSROOT}" ]] &&
	   [[ "${EN_CATALYST_SYSROOT}" != "/" ]]; then
	mkdir -p "${EN_CATALYST_SYSROOT}"/etc
	ln -s /etc/portage "${EN_CATALYST_SYSROOT}"/etc/portage

	# Preliminary support for SYSROOT update
	if [[ "${EN_CATALYST_UPDATE_SYSROOT}" == "yes" ]]; then
		echo Update SYSROOT: ROOT="${EN_CATALYST_SYSROOT}" emerge...
		while read en_clst_update_sysroot_command; do
			if [[ -n "${en_clst_update_sysroot_command}" ]]; then
				ROOT="${EN_CATALYST_SYSROOT}" run_merge ${en_clst_update_sysroot_command}
			fi
		done < <(echo "${EN_CATALYST_UPDATE_SYSROOT_COMMANDS}")
	fi

	SYSROOT="${EN_CATALYST_SYSROOT}" run_merge --implicit-system-deps=n --oneshot "${buildpkgs[@]}"
else
	run_merge --implicit-system-deps=n --oneshot "${buildpkgs[@]}"
fi

# TODO: Drop this when locale-gen in stable glibc supports ROOT.
#
# locale-gen does not support the ROOT variable, and as such glibc simply does
# not run locale-gen when ROOT is set. Since we've set LANG, we need to run
# locale-gen explicitly.
if [ -x "$(command -v locale-gen)" ]; then
	if ! locale-gen -V | grep -q '^locale-gen-2\.'; then
		locale-gen --config /etc/locale.gen --prefix "$ROOT"/
	else
		locale-gen --destdir "$ROOT"/
	fi || die "locale-gen failed"
fi

# Why are we removing these? Don't we need them for final make.conf?
for useexpand in ${clst_HOSTUSEEXPAND}; do
	x="clst_${useexpand}"
	sed -i "/${useexpand}=\"${!x}\"/d" \
	${clst_make_conf}
done

# Clear USE
[ -e ${clst_make_conf} ] && sed -i -e "/^CATALYST_USE/d" ${clst_make_conf}
[ -e ${clst_make_conf} ] && sed -i -e "/^USE=\"/s/\${CATALYST_USE} ${USE} ${BOOTSTRAP_USE}//" ${clst_make_conf}
