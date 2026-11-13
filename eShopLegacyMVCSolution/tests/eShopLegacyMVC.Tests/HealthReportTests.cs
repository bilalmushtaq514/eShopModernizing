using System;
using System.Collections.Generic;
using eShopLegacyMVC.Controllers;
using eShopLegacyMVC.Models;
using eShopLegacyMVC.Services;
using eShopLegacyMVC.ViewModel;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace eShopLegacyMVC.Tests
{
    [TestClass]
    public class HealthReportTests
    {
        [TestMethod]
        public void Healthy_when_mock_catalog_returns_items()
        {
            var report = HealthReport.Evaluate(new CatalogServiceMock(), "IIS01", "42-abc1234", "dev");

            Assert.IsTrue(report.Healthy);
            Assert.AreEqual("Healthy", report.Status);
            Assert.AreEqual("IIS01", report.Server);
            Assert.AreEqual("42-abc1234", report.Build);
            Assert.IsTrue(report.CatalogItems > 0);
        }

        [TestMethod]
        public void Unhealthy_when_catalog_throws()
        {
            var report = HealthReport.Evaluate(new ThrowingCatalogService(), "IIS02", null, null);

            Assert.IsFalse(report.Healthy);
            Assert.AreEqual("Unhealthy", report.Status);
            Assert.AreEqual("InvalidOperationException", report.Error);
            Assert.AreEqual("unknown", report.Build);
        }

        [TestMethod]
        public void Mock_catalog_paginates()
        {
            var page = new CatalogServiceMock().GetCatalogItemsPaginated(5, 0);

            Assert.AreEqual(5, page.ItemsPerPage);
            Assert.IsTrue(page.TotalItems >= 5);
        }

        private sealed class ThrowingCatalogService : ICatalogService
        {
            public PaginatedItemsViewModel<CatalogItem> GetCatalogItemsPaginated(int pageSize, int pageIndex)
                => throw new InvalidOperationException("database unreachable");
            public CatalogItem FindCatalogItem(int id) => throw new NotImplementedException();
            public IEnumerable<CatalogBrand> GetCatalogBrands() => throw new NotImplementedException();
            public IEnumerable<CatalogType> GetCatalogTypes() => throw new NotImplementedException();
            public void CreateCatalogItem(CatalogItem catalogItem) => throw new NotImplementedException();
            public void UpdateCatalogItem(CatalogItem catalogItem) => throw new NotImplementedException();
            public void RemoveCatalogItem(CatalogItem catalogItem) => throw new NotImplementedException();
            public void Dispose() { }
        }
    }
}
