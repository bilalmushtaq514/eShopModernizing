using System;
using System.Configuration;
using System.Linq;
using System.Web.Mvc;
using eShopLegacyMVC.Services;

namespace eShopLegacyMVC.Controllers
{
    /// <summary>
    /// [Deployment addition] GET /health
    /// Used by the internal load-balancer probe and by the pipeline's per-server and
    /// through-the-LB checks. Returns 200 only if the catalog can actually be read,
    /// and reports the server name + build so load balancing and versions are provable.
    /// </summary>
    public class HealthController : Controller
    {
        private readonly ICatalogService catalogService;

        public HealthController(ICatalogService catalogService)
        {
            this.catalogService = catalogService;
        }

        [HttpGet]
        [OutputCache(NoStore = true, Duration = 0, Location = System.Web.UI.OutputCacheLocation.None)]
        public ActionResult Index()
        {
            var report = HealthReport.Evaluate(
                catalogService,
                Environment.MachineName,
                ConfigurationManager.AppSettings["BuildVersion"],
                ConfigurationManager.AppSettings["EnvironmentName"]);

            Response.StatusCode = report.Healthy ? 200 : 503;
            Response.TrySkipIisCustomErrors = true;
            return Json(report, JsonRequestBehavior.AllowGet);
        }
    }

    /// <summary>Pure, unit-testable health evaluation (no HttpContext needed).</summary>
    public class HealthReport
    {
        public bool Healthy { get; set; }
        public string Status { get; set; }
        public string Server { get; set; }
        public string Build { get; set; }
        public string Environment { get; set; }
        public long CatalogItems { get; set; }
        public string Error { get; set; }

        public static HealthReport Evaluate(ICatalogService service, string server, string build, string environment)
        {
            var report = new HealthReport
            {
                Server = server,
                Build = string.IsNullOrEmpty(build) ? "unknown" : build,
                Environment = string.IsNullOrEmpty(environment) ? "unknown" : environment
            };

            try
            {
                var page = service.GetCatalogItemsPaginated(1, 0);
                report.CatalogItems = page.TotalItems;
                report.Healthy = page.TotalItems > 0 && page.Data.Any();
                report.Status = report.Healthy ? "Healthy" : "Unhealthy";
                if (!report.Healthy) report.Error = "Catalog is empty";
            }
            catch (Exception ex)
            {
                report.Healthy = false;
                report.Status = "Unhealthy";
                report.Error = ex.GetType().Name;
            }

            return report;
        }
    }
}
