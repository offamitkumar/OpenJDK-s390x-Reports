#!/bin/bash

# Get the current year, month, and day
year=$(date +%Y)
month=$(date +%B)
day=$(date +%d)
directory_path="/home/amit/OpenJDK-s390x-Reports/$year/$month/$day"

# helper methods
git_setup() {
  # Check if the branch exists in the remote or locally
  if git show-ref --verify --quiet refs/heads/"$year"; then
    echo "Branch '$year' already exists."
  else
    # Create and switch to the new branch
    git checkout -b "$year"
    echo "Branch '$year' created and checked out."
  fi
}

set_directories() {
  # Check if the year directory exists
  if [ ! -d "$year" ]; then
    mkdir "$year"
  fi

  # Check if the month directory inside the year directory exists
  if [ ! -d "$year/$month" ]; then
    mkdir "$year/$month"
  fi

  # Check if the day directory inside the month directory exists
  if [ ! -d "$year/$month/$day" ]; then
    mkdir "$year/$month/$day"
  fi

  mkdir "$year/$month/$day/fastdebug"
  mkdir "$year/$month/$day/release"
}

git_exit() {
  git add .
  git commit -m "$day/$month/$year"
  git push --set-upstream origin $year
}

jdk_fastdebug() {
  export CONF=linux-s390x-server-fastdebug

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=jtreg \
    --with-gtest=googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=fastdebug \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=jtreg \
    --with-gtest=googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=fastdebug \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-fastdebug/build.log  $directory_path/fastdebug/

  make run-test-tier1;

  cp build/linux-s390x-server-fastdebug/test-results/test-summary.txt $directory_path/fastdebug/

  cat $(find build/linux-s390x-server-fastdebug/ -name newfailures.txt) > $directory_path/fastdebug/newfailures.txt

  cat $(find build/linux-s390x-server-fastdebug/ -name other_errors.txt) > $directory_path/fastdebug/other_errors.txt
    #More test run with different JTREG Options

}

jdk_release() {
  export CONF=linux-s390x-server-release

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=jtreg \
    --with-gtest=googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=jtreg \
    --with-gtest=googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make images

  cp build/linux-s390x-server-release/build.log  $directory_path/release/

  make run-test-tier1;

  cp build/linux-s390x-server-release/test-results/test-summary.txt $directory_path/release/

  cat $(find build/linux-s390x-server-release/ -name newfailures.txt) > $directory_path/release/newfailures.txt

  cat $(find build/linux-s390x-server-release/ -name other_errors.txt) > $directory_path/release/other_errors.txt

  #More test run with different JTREG Options
}

build_test_jdk_head() {
  cd /home/amit/head/jdk
  git switch master
  git pull
  git log -1 > $directory_path/top_commit
  jdk_fastdebug;
  jdk_release;
  cd /home/amit/OpenJDK-s390x-Reports
}

# usage
git_setup
set_directories
build_test_jdk_head
git_exit #adds all the changes and do a git push
