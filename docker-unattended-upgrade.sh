#!/bin/bash
#
# This script can be configured to automatically update the running
# containers by checking for upgrades in them and if needed download
# new images that are also checked for updates before the decision
# is made whether to restart or not using the new images.
#
# To extend the script to support images based on other distros than
# Debian or Ubuntu, another check similar to this one should be added:
# "elif [[ "$(docker exec "${container_name}" whereis apt-get)" != 'apt-get:' ]]; then"
# as well as helper functions that uses the package manager for the
# specific distro, such as e.g. yum.

# TODO(john): Testing in a real test-environment with Nagios.
# TODO(john): Implementing optional suppression of output.

set -uf

# Nagios compatible exit-codes
OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3

# This variable will contain either yes or no depending
# on the decision reached by the script. Note that a
# default value for the variable is required with set -u
execute_containers_restart="no"

# To avoid doing duplicated checks the script stores info
# about which images it already has checked in this array.
# These are the possible states for each image:
#
#'unknown-update-status' <-- Default status
#'up-to-date'    <-- No action needed, already up-to-date
#'updated'       <-- A new, updated image has been downloaded
#'update-needed' <-- No fully patched image is available
#'unknown-image' <-- Unknown image that is probably not tagged
declare -A image_info

# To avoid duplicated lookups and miscalculations when
# e.g. an image, that is being used by multiple containers,
# has already been updated before checking the status of
# the container we store the initial info about each
# container in this array:
declare -A container_info

# Verify whether or not a new image is fully patched
# by starting a temporary container and check for updates.
check_if_new_apt_image_contains_upgrades()
{
    local -r __container_image="${1}"
    local -r __container_name="upgrade_test_$((RANDOM))"

    docker run -d \
        --name "${__container_name}" \
        --entrypoint /bin/bash -i \
        "${__container_image}" > /dev/null 2>&1

    local -r __apt_upgrade_available_result="$(check_if_apt_upgrade_is_available "${__container_name}")"

    # Remove the temporary container
    docker kill "${__container_name}" > /dev/null 2>&1
    docker rm "${__container_name}" > /dev/null 2>&1

    echo "${__apt_upgrade_available_result}"
}

check_if_apt_upgrade_is_available()
{
    local -r __container_name="${1}"
    local -r __apt_update_result="$(docker exec "${__container_name}" apt-get update 2>&1)"

    if [[ "${__apt_update_result}" =~ [fF]ailed ]]; then
        echo "Aborting: apt-get update failed in container: ${__container_name}"

    else
        # It's faster to check if the package exits than to always try to install it
        if [[ "$(docker exec "${__container_name}" which unattended-upgrades )" == '' ]]; then
            docker exec "${__container_name}" apt-get install -y unattended-upgrades > /dev/null 2>&1
        fi

        local -r __available_upgrades="$(docker exec "${__container_name}" unattended-upgrade -v --dry 2>&1)"

        if [[ "${__available_upgrades}" =~ "Packages that will be upgraded" ]]; then
            # To send both the result and info about which packages can
            # be upgraded, the returned string i split as a tuple by ",".
            echo -n "yes, $(echo -n "${__available_upgrades}" | \
                  grep -o "Packages that will be upgraded:.*" | \
                  cut -d':' -f2)"
        else
            echo -n "no"
        fi

    fi
}

main_apt_helper_function()
{
    local -r __container_name="${1}"
    local -r __container_image="${2}"

    local -r __apt_upgrade_available_result="$(check_if_apt_upgrade_is_available "${__container_name}")"

    if [[ "${__apt_upgrade_available_result}" == "no" ]]; then
        echo "Info: no update needed for: ${__container_image}"
        image_info["${__container_image}"]="up-to-date"

    elif [[ "${__apt_upgrade_available_result}" =~ ^Aborting ]]; then
        echo "${__apt_upgrade_available_result}"
        exit ${WARNING}

    elif [[ "${__apt_upgrade_available_result}" =~ ^yes ]]; then

        local -r __container_image_status="$(docker pull "${__container_image}" 2>&1)"

        # If Docker for some reason couldn't fetch the image due to e.g. network problems
        # we should abort and not try to restart using a potential broken image.
        if [[ ${?} != 0 ]]; then
            echo "Aborting: couldn't fetch the image: ${__container_image}"
            echo "Error message: ${__container_image_status}"
            exit ${WARNING}
        fi

        local -r __image_has_pending_updates="$(check_if_new_apt_image_contains_upgrades "${__container_image}")"

        if [[ "${__image_has_pending_updates}" == "no" ]]; then
            image_info["${__container_image}"]="updated"
            echo "Info: updated image downloaded: ${__container_image} - a container restart has been scheduled"
            execute_containers_restart="yes"

        elif [[ "${__image_has_pending_updates}" =~ ^yes ]]; then
            image_info["${__container_image}"]="update-needed"
            local -r available_upgrades="$(echo ${__apt_upgrade_available_result} | cut -d',' -f2)"
            echo "Warning: no updated ${__container_image} is available for: ${__container_name} although these updates are available:${available_upgrades}"

        else
            echo "Unknown: unexpected state of variable: __image_has_pending_updates"
            exit ${UNKNOWN}

        fi

    else
        echo "Unknown: unexpected state of variable: __apt_upgrade_available_result"
        exit ${UNKNOWN}

    fi
}

restart_container()
{
    local -r __restart_type="${1}"
    local -r __restart_name="${2}"

    echo "Trying to restart containers ..."
    echo ""

    if [[ "${__restart_type}" == "systemctl" ]]; then
        systemctl restart "${__restart_name}"
        systemctl status "${__restart_name}"

    elif [[ "${__restart_type}" == "service" ]]; then
        service "${__restart_name}" restart
        service "${__restart_name}" status

    elif [[ "${__restart_type}" == "compose" ]]; then
        docker-compose -f "${__restart_name}" up --no-build -d

    else
        echo "Invalid restart type: ${__restart_type}"
        exit ${UNKNOWN}

    fi
}

populate_docker_info()
{
    for container_name in $(docker ps --format "{{.Names}}")
    do
        local __container_image="$(docker ps --filter name="${container_name}" --format "{{.Image}}")"

        # If the image only contains numbers and digits it most likely
        # means that a newer image has been downloaded and the old one
        # has been untagged.
        if [[ "${__container_image}" =~ ^[a-z0-9]+$ ]]; then

            # If the syntax is still correct for this version of Docker
            # we might get info about which image the container was
            # started upon by using inspect instead of ps.
            local __container_config_image="$(docker inspect --format '{{.Config.Image}}' "${container_name}" 2>&1)"

            if [[ ${?} == 0 && "${__container_config_image}" != '' ]]; then
                image_info["${__container_image}"]='untagged-image'
                container_info["${container_name}"]="${__container_image}"
                echo "Warning: container: ${container_name} is running on an old, untagged version of: ${__container_config_image}"

            else
                echo "Critical: potential change in Docker API. Image for: ${container_name} is unknown"
                exit ${CRITICAL}

            fi

        else
            image_info["${__container_image}"]='unknown-update-status'
            container_info["${container_name}"]="${__container_image}"
        fi
    done
}

usage()
{
    local -r PROGNAME="${1}"

cat <<EOF

    usage: ${PROGNAME} options
    
    This script can be configured to automatically update the running containers by
    checking for upgrades in them and if needed download new images that are also checked
    for updates before the decision is made whether to restart or not using the new images.

    Examples:
       If updates are available, restart with systemctl:
       ${PROGNAME} systemctl my-docker-job.service

       If updates are available, restart with service:
       ${PROGNAME} service my-docker-job

       If updates are available, restart with Docker compose:
       ${PROGNAME} compose /path/to/my-docker-job.yml

EOF
}

main()
{
    if [[ $# != 2 ]]; then
        usage "${0}"
        exit ${UNKNOWN}
    fi

    local -r __restart_type="${1}" 
    local -r __restart_name="${2}"

    # Check if Docker is installed
    # Failing here is OK, since not all machines run Docker
    if [[ "$(which docker)" == '' ]]; then
        echo "Info: Docker is not installed"
        exit ${OK}
    fi

    # If docker is installed check if it's working correctly.
    # Failing here is not OK, since that means Docker is
    # installed but not working or failed to start.
    docker ps > /dev/null 2>&1
    if [[ ${?} != 0 ]]; then
        echo "Critical: Docker is not working correctly"
        exit ${CRITICAL}
    fi

    # Populate two arrays with info about the running
    # containers and images to use throughout the script.
    populate_docker_info

    if [[ ${#container_info[@]} -gt 10 ]]; then
        echo "Warning: with this many update checks from one IP you'll probably be rate limited ..."
    fi

    for container_name in $(docker ps --format "{{.Names}}")
    do

        local __container_image="${container_info["${container_name}"]}"

        # Avoid duplicated work by checking if the image that the
        # container started on have already been checked for updates.
        if [[ "${image_info["${__container_image}"]}" == 'up-to-date' ]]; then
            echo "Info: no update needed for: ${container_name}"
       
        elif [[ "${image_info["${__container_image}"]}" == 'updated' ]]; then
            echo "Info: a new updated image has already been downloaded for: ${container_name} - a container restart has been scheduled"
            execute_containers_restart="yes"

        elif [[ "${image_info["${__container_image}"]}" == 'update-needed' ]]; then
            echo "Warning: no updated ${__container_image} is available for: ${container_name} although updates are pending."
            execute_containers_restart="not-possible_update-needed"

        elif [[ "${image_info["${__container_image}"]}" == 'untagged-image' ]]; then
            echo "Info: container: ${container_name} is not running on a currently tagged image - a container restart has been scheduled"
            execute_containers_restart="yes"

        elif [[ "$(docker exec "${container_name}" whereis whereis 2>&1)" =~ "invalid header field value" ]]; then
            echo "Warning: cannot check what package manager container: ${container_name} is using"
 
        # Check if the container is running on an apt-based distro.
        # whereis is used because it's included in both Debian and Fedora-based distros.
        elif [[ "$(docker exec "${container_name}" whereis apt-get)" != 'apt-get:' ]]; then
            main_apt_helper_function "${container_name}" "${__container_image}"

        # Check first that the container is still running before stating
        # that it's running on an unsupported image.
        elif [[ "$(docker ps --format "{{.Names}}" | grep ${container_name})" != "${container_name}" ]]; then
            echo "Warning: container: ${container_name} has stopped since starting the script"

       else 
            echo "Warning: container: ${container_name} is using an unsupported image: ${__container_image}"

        fi

    done

    if [[ "${execute_containers_restart}" == "yes" ]]; then
        restart_container "${__restart_type}" "${__restart_name}"
        echo ""
        echo "Info: Container restart issued"
        exit ${OK}
    elif [[ "${execute_containers_restart}" == "no" ]]; then
        echo ""
        echo "OK: no update needed"
        exit ${OK}
    elif [[ "${execute_containers_restart}" == "not-possible_update-needed" ]]; then
        echo ""
        echo "Warning: no updated image available although updates are pending"
        exit ${WARNING}
    else
        echo ""
        echo "Unknown: unexpected state of variable: execute_containers_restart"
        exit ${UNKNOWN}
    fi
}

# Execute the main function that calls helper-
# functions to deal with each task.
main "${@}"
