# Measuring the length of a noisy trace

The digitizer gives a sequence of points $(x_i, y_i)$ in millimeters. On the
inspection strip the trace is a graph over the horizontal axis, so the points
can be ordered by increasing $x_i$. A polyline through the samples will usually
look longer when the vertical measurement noise increases.

## Fit over the measured interval

Use a quadratic fit when the inspection range contains one gentle bend. Center
the input at its mean before solving to reduce the scale difference among the
columns of the design matrix. Write $t_i = x_i - \bar{x}$ and let
\(f(t) = a + bt + ct^2\). Find $a$, $b$, and $c$ by minimizing

$$
Q(a,b,c) = \sum_{i=1}^{n} \bigl(y_i - a - bt_i - ct_i^2\bigr)^2.
$$

This fit treats the horizontal positions as fixed. If adjacent residuals have
the same sign over most of the interval, try a different model or report the
measurement as unresolved. Check the fit before comparing lengths across strips.

## Integrate the fitted slope

The arclength over the measured interval follows from the slope $f'(t)$:

$$
L = \int_{t_1}^{t_n} \sqrt{1 + \bigl(b + 2ct\bigr)^2}\,dt
\label{eq:trace-length}
$$

Sample the integrand at equally spaced nodes and apply the trapezoidal rule to
Equation \ref{eq:trace-length}. Double the number of intervals until the
rounded length settles at the precision used by the inspection report.

\[
\begin{aligned}
  h &= \frac{t_n-t_1}{m}, \qquad g(t) = \sqrt{1 + (b+2ct)^2}, \\
  L_m &= h \left(\frac{g(t_1)+g(t_n)}{2} +
              \sum_{j=1}^{m-1}g(t_1+jh)\right).
\end{aligned}
\]

## Comparison run

The example trace spans 20 mm horizontally. Keep the units attached to the
fitted coefficients throughout the calculation, particularly when the input
file was captured in micrometers. The preliminary review used this check:

| Estimate | Length in mm | Interpretation |
| --- | ---: | --- |
| Horizontal span | 20.00 | Lower bound for a graph over the interval |
| Fitted arclength | 20.13 | Value to report when the residuals are small |
| Raw polyline | 20.27 | Sensitive to vertical measurement noise |

The integration error can be small even when the fit is poor.
Keep the residual plot with the estimate.
