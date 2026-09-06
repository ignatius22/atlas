(function () {
  "use strict";

  if (localStorage.getItem("vexeldarktheme")) {
    document.querySelector("html").setAttribute("data-theme-mode", "dark");
    document.querySelector("html").setAttribute("data-menu-styles", "dark");
    document.querySelector("html").setAttribute("data-header-styles", "dark");
  }
  if (localStorage.vexelrtl) {
    let html = document.querySelector("html");
    html.setAttribute("dir", "rtl");
    document.querySelector("#style")?.setAttribute("href","../assets/libs/bootstrap/css/bootstrap.rtl.min.css");
  }
   if (localStorage.vexellayout) {
    let html = document.querySelector('html');
    html.setAttribute("data-nav-layout", "horizontal");
    document.querySelector("html").setAttribute("data-menu-styles", "light")
}
if (localStorage.getItem("vexellayout") == "horizontal") {
    document.querySelector("html").setAttribute("data-nav-layout", "horizontal")
}

  if (localStorage.loaderEnable == "true") {
    document.querySelector("html").setAttribute("loader", "enable");
  } else {
    if (!document.querySelector("html").getAttribute("loader")) {
      document.querySelector("html").setAttribute("loader", "disable");
    }
  }

  function localStorageBackup() {
    // if there is a value stored, update color picker and background color
    // Used to retrive the data from local storage
    if (localStorage.primaryRGB) {
      if (document.querySelector(".theme-container-primary")) {
        document.querySelector(".theme-container-primary").value =
          localStorage.primaryRGB;
      }
      document
        .querySelector("html")
        .style.setProperty("--primary-rgb", localStorage.primaryRGB);
    }
    if (localStorage.bodyBgRGB && localStorage.bodylightRGB) {
      if (document.querySelector(".theme-container-background")) {
        document.querySelector(".theme-container-background").value =
          localStorage.bodyBgRGB;
      }
      document
        .querySelector("html")
        .style.setProperty("--body-bg-rgb", localStorage.bodyBgRGB);
      document
        .querySelector("html")
        .style.setProperty("--body-bg-rgb2", localStorage.bodyBgRGB2);
      document
        .querySelector("html")
        .style.setProperty("--light-rgb", localStorage.bodylightRGB);
      document
        .querySelector("html")
        .style.setProperty(
          "--form-control-bg",
          `rgb(${localStorage.bodylightRGB})`
        );
      document
        .querySelector("html")
        .style.setProperty("--input-border", "rgba(255,255,255,0.1)");
      let html = document.querySelector("html");
      html.setAttribute("data-theme-mode", "dark");
      html.setAttribute("data-menu-styles", "dark");
      html.setAttribute("data-header-styles", "dark");
    }
    if (localStorage.vexelMenu == "dark") {
      let html = document.querySelector("html");
      html.setAttribute("data-theme-mode", "dark");
    }
    if (localStorage.getItem("vexelHeader") == "dark") {
      let html = document.querySelector("html");
      html.setAttribute("data-header-styles", "dark");
    }
    if (localStorage.vexellayout) {
      let html = document.querySelector("html");
      let layoutValue = localStorage.getItem("vexellayout");
      html.setAttribute("data-nav-layout", "horizontal");

      setTimeout(() => {
        if (!document.querySelector(".login-img")) {
          clearNavDropdown();
        }
      }, 1000);
      html.setAttribute("data-nav-style", "menu-click");

      setTimeout(() => {
        if (!document.querySelector(".login-img")) {
          checkHoriMenu();
        }
      }, 1000);
    }
    if (localStorage.vexelverticalstyles) {
      let html = document.querySelector("html");
      let verticalStyles = localStorage.getItem("vexelverticalstyles");

      if (verticalStyles == "default") {
        html.setAttribute("data-vertical-style", "default");
        localStorage.removeItem("vexelnavstyles");
      }
      if (verticalStyles == "closed") {
        html.setAttribute("data-vertical-style", "closed");
        localStorage.removeItem("vexelnavstyles");
      }
      if (verticalStyles == "icontext") {
        html.setAttribute("data-vertical-style", "icontext");
        localStorage.removeItem("vexelnavstyles");
      }
      if (verticalStyles == "overlay") {
        html.setAttribute("data-vertical-style", "overlay");
        localStorage.removeItem("vexelnavstyles");
      }
      if (verticalStyles == "detached") {
        html.setAttribute("data-vertical-style", "detached");
        localStorage.removeItem("vexelnavstyles");
      }
      if (verticalStyles == "doublemenu") {
        html.setAttribute("data-vertical-style", "doublemenu");
        localStorage.removeItem("vexelnavstyles");
      }
    }
    if (localStorage.vexelnavstyles) {
      let html = document.querySelector("html");
      let navStyles = localStorage.getItem("vexelnavstyles");
      if (navStyles == "menu-click") {
        html.setAttribute("data-nav-style", "menu-click");
        localStorage.removeItem("vexelverticalstyles");
        html.removeAttribute("data-vertical-style");
      }
      if (navStyles == "menu-hover") {
        html.setAttribute("data-nav-style", "menu-hover");
        localStorage.removeItem("vexelverticalstyles");
        html.removeAttribute("data-vertical-style");
      }
      if (navStyles == "icon-click") {
        html.setAttribute("data-nav-style", "icon-click");
        localStorage.removeItem("vexelverticalstyles");
        html.removeAttribute("data-vertical-style");
      }
      if (navStyles == "icon-hover") {
        html.setAttribute("data-nav-style", "icon-hover");
        localStorage.removeItem("vexelverticalstyles");
        html.removeAttribute("data-vertical-style");
      }
    }
    if (localStorage.vexelclassic) {
      let html = document.querySelector("html");
      html.setAttribute("data-page-style", "classic");
    }
    if (localStorage.vexelboxed) {
      let html = document.querySelector("html");
      html.setAttribute("data-width", "boxed");
    }
    if (localStorage.vexelheaderfixed) {
      let html = document.querySelector("html");
      html.setAttribute("data-header-position", "fixed");
    }
    if (localStorage.vexelheaderscrollable) {
      let html = document.querySelector("html");
      html.setAttribute("data-header-position", "scrollable");
    }
    if (localStorage.vexelmenufixed) {
      let html = document.querySelector("html");
      html.setAttribute("data-menu-position", "fixed");
    }
    if (localStorage.vexelmenuscrollable) {
      let html = document.querySelector("html");
      html.setAttribute("data-menu-position", "scrollable");
    }
    if (localStorage.vexelMenu) {
      let html = document.querySelector("html");
      let menuValue = localStorage.getItem("vexelMenu");
      switch (menuValue) {
        case "light":
          html.setAttribute("data-menu-styles", "light");
          break;
        case "dark":
          html.setAttribute("data-menu-styles", "dark");
          break;
        case "color":
          html.setAttribute("data-menu-styles", "color");
          break;
        case "gradient":
          html.setAttribute("data-menu-styles", "gradient");
          break;
        case "transparent":
          html.setAttribute("data-menu-styles", "transparent");
          break;
        default:
          break;
      }
    }
    if (localStorage.vexelHeader) {
      let html = document.querySelector("html");
      let headerValue = localStorage.getItem("vexelHeader");
      switch (headerValue) {
        case "light":
          html.setAttribute("data-header-styles", "light");
          break;
        case "dark":
          html.setAttribute("data-header-styles", "dark");
          break;
        case "color":
          html.setAttribute("data-header-styles", "color");
          break;
        case "gradient":
          html.setAttribute("data-header-styles", "gradient");
          break;
        case "transparent":
          html.setAttribute("data-header-styles", "transparent");
          break;

        default:
          break;
      }
    }
    if (localStorage.bgimg) {
      let html = document.querySelector("html");
      let value = localStorage.getItem("bgimg");
      html.setAttribute("data-bg-img", value);
    }
  }
  localStorageBackup();
})();
