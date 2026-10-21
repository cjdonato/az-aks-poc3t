// Preloaded with `node --import ./src/telemetry.js` so OpenTelemetry can patch http,
// express and pg before index.js imports them (ESM can't be patched after loading).
// Without APPLICATIONINSIGHTS_CONNECTION_STRING (local runs, tests) nothing is loaded.
const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

// Kubelet probes hit these every few seconds; tracing them (and /readyz's SELECT 1)
// would be most of the telemetry volume.
const PROBE_PATHS = new Set(['/healthz', '/readyz']);

let shutdown = async () => {};

if (connectionString) {
  // Registers the ESM import hooks; must come before the instrumented modules load.
  await import('@microsoft/opentelemetry/loader');
  const { WorkloadIdentityCredential } = await import('@azure/identity');
  const { useMicrosoftOpenTelemetry, shutdownMicrosoftOpenTelemetry } = await import(
    '@microsoft/opentelemetry'
  );
  const { registerInstrumentations } = await import('@opentelemetry/instrumentation');
  const { ExpressInstrumentation } = await import('@opentelemetry/instrumentation-express');

  useMicrosoftOpenTelemetry({
    azureMonitor: {
      azureMonitorExporterOptions: {
        connectionString,
        // Application Insights has local (key) auth disabled: the pod authenticates
        // with its workload identity, which has Monitoring Metrics Publisher on it.
        credential: new WorkloadIdentityCredential(),
      },
    },
    instrumentationOptions: {
      http: {
        enabled: true,
        ignoreIncomingRequestHook: (req) => PROBE_PATHS.has(req.url?.split('?')[0]),
      },
      postgreSql: { enabled: true },
      // console.* calls become traces correlated with the request that logged them.
      console: { enabled: true },
    },
  });

  // Not bundled with the distro; gives requests their route name (GET /api/items/:id)
  // instead of the raw URL.
  registerInstrumentations({
    instrumentations: [new ExpressInstrumentation({ ignoreLayersType: ['middleware'] })],
  });

  shutdown = shutdownMicrosoftOpenTelemetry;
}

// Flushes buffered telemetry; called on shutdown so the last requests aren't lost.
export function shutdownTelemetry() {
  return shutdown();
}
