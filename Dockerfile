# Copyright (c) 2018, 2020 Oracle and/or its affiliates. All rights reserved.
# Portions Copyright (c) 2020, Chris Fraire <cfraire@me.com>.

FROM ubuntu:bionic as build

# hadolint ignore=DL3008
RUN apt-get update && apt-get install --no-install-recommends -y maven python3 python3-venv && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create a first layer to cache the "Maven World" in the local repository.
# Incremental docker builds will always resume after that, unless you update the pom
WORKDIR /mvn
COPY pom.xml /mvn/
COPY opengrok-indexer/pom.xml /mvn/opengrok-indexer/
COPY opengrok-web/pom.xml /mvn/opengrok-web/
COPY plugins/pom.xml /mvn/plugins/
COPY suggester/pom.xml /mvn/suggester/

# distribution and tools do not have dependencies to cache
RUN sed -i 's:<module>distribution</module>::g' /mvn/pom.xml && \
    sed -i 's:<module>tools</module>::g' /mvn/pom.xml && \
    mkdir -p /mvn/opengrok-indexer/target/jflex-sources && \
    mkdir -p /mvn/opengrok-web/src/main/webapp/js && \
    mkdir -p /mvn/opengrok-web/src/main/webapp/WEB-INF/ && \
    touch /mvn/opengrok-web/src/main/webapp/WEB-INF/web.xml

# dummy build to cache the dependencies
RUN mvn -DskipTests -Dcheckstyle.skip -Dmaven.antrun.skip package

# build the project
COPY ./ /opengrok-source
WORKDIR /opengrok-source

RUN mvn -DskipTests=true -Dmaven.javadoc.skip=true -B -V package
# hadolint ignore=SC2012,DL4006
RUN cp `ls -t distribution/target/*.tar.gz | head -1` /opengrok.tar.gz

FROM tomcat:10-jdk11
LABEL maintainer="https://github.com/oracle/opengrok"

# install dependencies and Python tools
# hadolint ignore=DL3008,DL3009
RUN apt-get update && \
    apt-get install --no-install-recommends -y git subversion mercurial unzip inotify-tools python3 python3-pip \
    python3-venv python3-setuptools

# compile and install universal-ctags
# hadolint ignore=DL3003,DL3008
RUN apt-get install --no-install-recommends -y pkg-config automake build-essential && \
    git clone https://github.com/universal-ctags/ctags /root/ctags && \
    cd /root/ctags && ./autogen.sh && ./configure && make && make install && \
    apt-get remove -y automake build-essential && \
    apt-get -y autoremove && apt-get -y autoclean && \
    cd /root && rm -rf /root/ctags && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# prepare OpenGrok binaries and directories
# hadolint ignore=DL3010
COPY --from=build opengrok.tar.gz /opengrok.tar.gz
# hadolint ignore=DL3013
RUN mkdir -p /opengrok /opengrok/etc /opengrok/data /opengrok/src && \
    tar -zxvf /opengrok.tar.gz -C /opengrok --strip-components 1 && \
    rm -f /opengrok.tar.gz && \
    python3 -m pip install --no-cache-dir /opengrok/tools/opengrok-tools* && \
    python3 -m pip install --no-cache-dir Flask Flask-HTTPAuth waitress # for /reindex REST endpoint handled by start.py

# environment variables
ENV SRC_ROOT /opengrok/src
ENV DATA_ROOT /opengrok/data
ENV URL_ROOT /
ENV CATALINA_HOME /usr/local/tomcat
ENV CATALINA_BASE /usr/local/tomcat
ENV CATALINA_TMPDIR /usr/local/tomcat/temp
ENV PATH $CATALINA_HOME/bin:$PATH
ENV CLASSPATH /usr/local/tomcat/bin/bootstrap.jar:/usr/local/tomcat/bin/tomcat-juli.jar

# disable all file logging
COPY docker/logging.properties /usr/local/tomcat/conf/logging.properties
RUN sed -i -e 's/Valve/Disabled/' /usr/local/tomcat/conf/server.xml

# add our scripts
COPY docker /scripts
RUN chmod -R +x /scripts

# run
WORKDIR $CATALINA_HOME
EXPOSE 8080
CMD ["/scripts/start.py"]
