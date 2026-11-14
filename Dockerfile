# installs corazana for nginx as modsec receives less efforts now
# https://www.f5.com/company/blog/nginx/f5-nginx-modsecurity-waf-transitioning-to-eol
# https://www.coraza.io/

ARG nginx_version=1.31.8

FROM golang:trixie AS coraza_build
ARG nginx_version

RUN apt update

# required later here to fetch data from repos
RUN apt install -y wget git
# build requirements https://github.com/corazawaf/libcoraza#prerequisites
RUN apt install -y clang libtool autotools-dev make
# required for building nginx module
RUN apt install -y libpcre2-dev zlib1g-dev

WORKDIR /go/

# nginx source
RUN wget https://nginx.org/download/nginx-$nginx_version.tar.gz 
RUN tar -xzvf nginx-$nginx_version.tar.gz
# libcorazana
RUN git clone https://github.com/corazawaf/libcoraza libcoraza
# nginx corazana module
RUN git clone https://github.com/corazawaf/coraza-nginx.git

WORKDIR /go/libcoraza/

# follows https://github.com/corazawaf/coraza-nginx#compilation and https://github.com/corazawaf/libcoraza#build
RUN ./build.sh && ./configure && make && make install && ldconfig

WORKDIR /go/nginx-$nginx_version/

# follows build instrutions https://github.com/corazawaf/coraza-nginx#compilation 
# https://www.f5.com/company/blog/nginx/compiling-dynamic-modules-nginx-plus
RUN ./configure --add-dynamic-module=/go/coraza-nginx --with-compat
RUN make modules

WORKDIR /go/
# installs core ruleset manually https://www.coraza.io/docs/tutorials/coreruleset/#manual-installation
RUN wget https://raw.githubusercontent.com/corazawaf/coraza/main/coraza.conf-recommended -O coraza.conf
RUN git clone https://github.com/coreruleset/coreruleset
# enables blocking mode
RUN sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/g' coraza.conf
# debug logs visible in docker logs (container's stderr), as done for nginx https://github.com/nginx/docker-nginx/blob/master/stable/debian/Dockerfile#L133
RUN sed -i 's/#SecDebugLog \/opt\/coraza\/var\/log\/debug.log/SecDebugLog \/dev\/stderr/g' coraza.conf
# debug logs to log errors only
RUN sed -i 's/#SecDebugLogLevel 3/SecDebugLogLevel 1/g' coraza.conf
# audot logs visible in docker logs (container's stdout), as done for nginx https://github.com/nginx/docker-nginx/blob/master/stable/debian/Dockerfile#L133
RUN sed -i 's/#SecAuditLog \/opt\/coraza\/var\/log\/audit.log/SecAuditLog \/dev\/stdout/g' coraza.conf


FROM nginx:$nginx_version
ARG nginx_version

# needed for nginx module loading to find the lib: https://github.com/corazawaf/coraza-nginx#runtime-library-loading
# https://github.com/corazawaf/libcoraza#build-offline-or-different-branchcommit
ENV LD_LIBRARY_PATH=/etc/nginx/modules/libcoraza/:$LD_LIBRARY_PATH
# gets dynamic library from build stage
COPY --from=coraza_build /usr/local/lib/libcoraza.* /etc/nginx/modules/libcoraza/
COPY --from=coraza_build /usr/local/include/coraza/coraza.h /etc/nginx/modules/libcoraza/

# gets module
COPY --from=coraza_build /go/nginx-$nginx_version/objs/ngx_http_coraza_module.so /etc/nginx/modules/

# setup standard conf files https://www.coraza.io/
COPY --from=coraza_build /go/coraza.conf /etc/coraza/
COPY --from=coraza_build /go/coreruleset/crs-setup.conf.example /etc/coraza/crs-setup.conf
COPY --from=coraza_build /go/coreruleset/rules/ /etc/coraza/rules/