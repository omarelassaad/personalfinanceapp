FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
COPY manifest.json /usr/share/nginx/html/manifest.json
COPY icon.svg /usr/share/nginx/html/icon.svg
EXPOSE 80
