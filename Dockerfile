FROM gcr.io/distroless/static-debian13:nonroot@sha256:1c2c046bc09ed40fad370b599a0b1ae7987f55b01e247cf27a7c27cd97e5bbc7

ARG TARGETARCH

WORKDIR /app
COPY --chown=65532:65532 build/${TARGETARCH}/rootfs/ /app/

USER 65532:65532
EXPOSE 9090
VOLUME ["/app/data"]

ENTRYPOINT ["/app/rulego-server"]
CMD ["-c", "/app/config.conf"]
