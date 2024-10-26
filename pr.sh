#!/bin/bash

# Check if a PR is provided
if [ -z "$1" ]; then
    echo "Usage: sh pr.sh <PR-NUMBER>"
    exit 1
fi

# Assign the first argument to a variable
PR_NUMBER=$1

directory_path="/home/amit/OpenJDK-s390x-Reports/PRs/$PR_NUMBER"

# helper methods
git_setup() {
  # Check if the branch exists in the remote or locally
    if git show-ref --verify --quiet refs/heads/"PR"; then
      echo "Branch 'PR' already exists."
    else
      # Create and switch to the new branch
      git checkout -b "PR"
      echo "Branch 'PR' created and checked out."
    fi
}

set_directories() {
  if [ ! -d "PRs" ]; then
    mkdir "PRs"
  fi

  if [ ! -d "PRs/$PR_NUMBER" ]; then
    mkdir "PRs/$PR_NUMBER"
  fi
  if [ ! -d "PRs/$PR_NUMBER/fastdebug" ]; then
    mkdir "PRs/$PR_NUMBER/fastdebug"
  fi

   if [ ! -d "PRs/$PR_NUMBER/release" ]; then
     mkdir "PRs/$PR_NUMBER/release"
   fi
}

git_exit() {
  git add .
  git commit -m "$(date)"
  git push --set-upstream origin "PR"
}

jdk_fastdebug() {
  export CONF=linux-s390x-server-fastdebug

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=fastdebug \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=$HOME/jtreg \
    --with-gtest=$HOME/googletest \
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
    --with-jtreg=$HOME/jtreg \
    --with-gtest=googletest \
    --with-jmh=build/jmh/jars \
    --with-debug-level=release \
    --with-native-debug-symbols=internal \
    --disable-precompiled-headers

  make clean;
  make dist-clean;

  bash configure \
    --with-boot-jdk=boot_jdk_23 \
    --with-jtreg=$HOME/jtreg \
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
  cd /home/amit/jdk

    if git show-ref --verify --quiet refs/heads/$PR_NUMBER; then
      git checkout pull/$PR_NUMBER
      git pull https://git.openjdk.org/jdk.git pull/$PR_NUMBER/head
    else
      # Create and switch to the new branch
      git switch master
      git fetch https://git.openjdk.org/jdk.git pull/$PR_NUMBER/head:pull/$PR_NUMBER
      git checkout pull/$PR_NUMBER
    fi

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
