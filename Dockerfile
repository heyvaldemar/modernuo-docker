# ==========================================================================
# ModernUO — Ultima Online shard server (.NET 10, modernuo/ModernUO).
# Built from source because upstream ships NO Docker image and its releases
# carry no prebuilt binaries. Multi-stage: SDK builds, runtime ships.
#
# The build tool needs git history (it stamps the BuildTool commit), so we
# clone rather than COPY. Pin MODERNUO_REF to a release tag for reproducible
# rebuilds — uowatch alerts when a newer release appears (diun can't watch a
# locally-built image).
# ==========================================================================
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ARG MODERNUO_REF=main
RUN git clone https://github.com/modernuo/ModernUO.git . \
    && git checkout "${MODERNUO_REF}"
RUN ./publish.sh release linux x64

FROM mcr.microsoft.com/dotnet/runtime:10.0
# ModernUO P/Invokes native libs that the stock runtime image lacks:
# libdeflate (save compression) — without it the server dies at Core.Setup.
RUN apt-get update && apt-get install -y --no-install-recommends libdeflate0 libargon2-1 \
    && rm -rf /var/lib/apt/lists/* \
    # Debian ships only the versioned libdeflate.so.0, but .NET's DllImport
    # resolves the UNVERSIONED name — without this symlink the server dies with
    # "Could not load libdeflate" at Core.Setup.
    && ln -sf /usr/lib/x86_64-linux-gnu/libdeflate.so.0 /usr/lib/x86_64-linux-gnu/libdeflate.so \
    && ln -sf /usr/lib/x86_64-linux-gnu/libargon2.so.1 /usr/lib/x86_64-linux-gnu/libargon2.so
WORKDIR /app
COPY --from=build /src/Distribution /app
# Shard data (accounts, world saves) and the UO client art/map files are mounted.
VOLUME ["/app/Saves", "/uodata"]
EXPOSE 2593/tcp
ENTRYPOINT ["dotnet", "ModernUO.dll"]
